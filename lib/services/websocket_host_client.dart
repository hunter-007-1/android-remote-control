import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/message_protocol.dart';
import '../config/server_config.dart';

/// WebSocket Host 客户端
/// 用于被控端，作为客户端连接到服务器
/// 连接格式: ws://server/?role=host&id=[六位设备码]
class WebSocketHostClient {
  WebSocketChannel? _channel;
  bool _isConnected = false;
  String? _deviceCode;
  String? _serverUrl;

  final StreamController<Message> _messageController =
      StreamController<Message>.broadcast();
  final StreamController<WebSocketConnectionState> _connectionStateController =
      StreamController<WebSocketConnectionState>.broadcast();

  bool get isConnected => _isConnected;
  String? get deviceCode => _deviceCode;
  Stream<Message> get messageStream => _messageController.stream;
  Stream<WebSocketConnectionState> get connectionStateStream =>
      _connectionStateController.stream;

  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const int maxReconnectAttempts = 5;
  static const Duration reconnectDelay = Duration(seconds: 3);

  /// 连接断开回调
  VoidCallback? onConnectionLost;

  /// 连接到服务器
  /// [deviceCode] 六位数字设备码
  /// [serverUrl] 服务器地址，默认为 ServerConfig.defaultServerUrl
  Future<bool> connect(String deviceCode, {String? serverUrl}) async {
    if (_isConnected && _deviceCode == deviceCode) {
      return true;
    }

    _deviceCode = deviceCode;
    _serverUrl = serverUrl ?? ServerConfig.defaultServerUrl;
    return _doConnect();
  }

  Future<bool> _doConnect() async {
    try {
      if (_deviceCode == null || _serverUrl == null) {
        return false;
      }

      _connectionStateController.add(WebSocketConnectionState.connecting);

      final url = '$_serverUrl/?role=host&id=$_deviceCode';
      print('WebSocketHostClient: 连接到 $url');

      _channel = WebSocketChannel.connect(Uri.parse(url));

      final completer = Completer<bool>();

      _channel!.stream.listen(
        (message) {
          _handleMessage(message);
        },
        onError: (error) {
          print('WebSocketHostClient 错误: $error');
          _handleDisconnect();
        },
        onDone: () {
          print('WebSocketHostClient 连接关闭');
          _handleDisconnect();
        },
      );

      await Future.delayed(const Duration(milliseconds: 500));

      if (_channel != null) {
        _isConnected = true;
        _reconnectAttempts = 0;
        _connectionStateController.add(WebSocketConnectionState.connected);
        _startHeartbeat();
        print('WebSocketHostClient: 连接成功');
        return true;
      } else {
        _connectionStateController.add(WebSocketConnectionState.disconnected);
        return false;
      }
    } catch (e) {
      print('WebSocketHostClient 连接失败: $e');
      _connectionStateController.add(WebSocketConnectionState.disconnected);
      _attemptReconnect();
      return false;
    }
  }

  /// 处理消息（支持 Binary 通道的指令检测）
  void _handleMessage(dynamic message) {
    try {
      if (message is String) {
        // Text 消息处理
        _handleTextMessage(message);
      } else if (message is Uint8List) {
        // Binary 消息处理
        _handleBinaryMessage(message);
      }
    } catch (e) {
      print('WebSocketHostClient 处理消息失败: $e');
    }
  }

  /// 处理 Binary 消息（包含防误判补丁）
  void _handleBinaryMessage(Uint8List data) {
    // 核心补丁：通过数据大小区分"指令"和"视频"
    // 视频帧通常 > 1000 字节，指令通常 < 500 字节
    if (data.length < 500) {
      try {
        // 尝试把这些字节当作字符串解析
        final command = String.fromCharCodes(data);
        print('WebSocketHostClient: ⚠️ 在二进制通道收到小数据: ${data.length}字节, 尝试解析为指令');

        // 检查是否是有效的 JSON
        if (command.trim().startsWith('{') || command.trim().startsWith('[')) {
          print('WebSocketHostClient: 检测到 JSON 格式指令: $command');
          _handleTextMessage(command);
          return; // 是指令，处理完直接返回
        }
      } catch (e) {
        print('WebSocketHostClient: 解析二进制指令失败: $e');
      }
    }

    // 真正的视频帧，直接忽略（服务器已经透传给控制端了）
    print('WebSocketHostClient: 收到视频帧 ${data.length} 字节（被控端不处理）');
  }

  /// 处理 Text 消息
  void _handleTextMessage(String message) {
    try {
      final json = jsonDecode(message) as Map<String, dynamic>;

      // 检查是否是自定义指令（CLICK, SWIPE, KEY）
      final type = json['type'] as String?;
      if (type != null &&
          ['CLICK', 'SWIPE', 'KEY'].contains(type.toUpperCase())) {
        // 自定义指令，包装为 error 类型传递（兼容原有处理逻辑）
        print('WebSocketHostClient: 收到自定义指令: $type');
        final msg = Message(
          type: MessageType.error,
          data: json,
        );
        _messageController.add(msg);
      } else {
        // 标准协议消息
        print('WebSocketHostClient: 收到标准协议消息: $type');
        final msg = Message.fromJson(json);
        _messageController.add(msg);
      }
    } catch (e) {
      print('WebSocketHostClient 处理 Text 消息失败: $e');
    }
  }

  /// 发送屏幕帧（直接发送 Binary，不加 JSON 包装）
  Future<bool> sendScreenFrame(Uint8List imageData) async {
    if (!_isConnected || _channel == null) {
      return false;
    }

    try {
      // 直接发送二进制数据，服务器会透传给控制端
      _channel!.sink.add(imageData);
      return true;
    } catch (e) {
      print('WebSocketHostClient 发送屏幕帧失败: $e');
      return false;
    }
  }

  /// 发送消息
  Future<bool> sendMessage(Message message) async {
    if (!_isConnected || _channel == null) {
      return false;
    }

    try {
      _channel!.sink.add(message.toJsonString());
      return true;
    } catch (e) {
      print('WebSocketHostClient 发送消息失败: $e');
      return false;
    }
  }

  /// 启动心跳
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    // 每 30 秒发送一次心跳包
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (_isConnected) {
        sendMessage(Message.heartbeat());
      }
    });
  }

  /// 处理断开连接
  void _handleDisconnect() {
    if (!_isConnected) {
      return;
    }

    _isConnected = false;
    _connectionStateController.add(WebSocketConnectionState.disconnected);
    _heartbeatTimer?.cancel();

    // 触发连接断开回调
    onConnectionLost?.call();

    _attemptReconnect();
  }

  /// 尝试重连
  void _attemptReconnect() {
    if (_reconnectAttempts >= maxReconnectAttempts) {
      print('WebSocketHostClient: 达到最大重连次数，停止重连');
      return;
    }

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(reconnectDelay, () {
      _reconnectAttempts++;
      print(
          'WebSocketHostClient: 尝试重连 ($_reconnectAttempts/$maxReconnectAttempts)...');
      _doConnect();
    });
  }

  /// 断开连接
  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();

    await _channel?.sink.close();
    _channel = null;
    _isConnected = false;
    _reconnectAttempts = 0;
    _connectionStateController.add(WebSocketConnectionState.disconnected);

    print('WebSocketHostClient: 已断开连接');
  }

  void dispose() {
    disconnect();
    _messageController.close();
    _connectionStateController.close();
  }
}

/// WebSocket 连接状态
enum WebSocketConnectionState {
  connecting,
  connected,
  disconnected,
  error,
}
