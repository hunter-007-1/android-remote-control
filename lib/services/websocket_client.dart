import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/message_protocol.dart';

/// WebSocket 客户端
/// 用于控制端，连接到被控端并接收屏幕数据
class WebSocketClient {
  WebSocketChannel? _channel;
  bool _isConnected = false;
  String? _url;

  final StreamController<Message> _messageController =
      StreamController<Message>.broadcast();
  final StreamController<WebSocketConnectionState> _connectionStateController =
      StreamController<WebSocketConnectionState>.broadcast();

  bool get isConnected => _isConnected;
  Stream<Message> get messageStream => _messageController.stream;
  Stream<WebSocketConnectionState> get connectionStateStream =>
      _connectionStateController.stream;

  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const int maxReconnectAttempts = 5;
  static const Duration reconnectDelay = Duration(seconds: 3);

  /// 连接到服务器
  Future<bool> connect(String url) async {
    if (_isConnected && _url == url) {
      return true;
    }

    _url = url;
    return _doConnect();
  }

  Future<bool> _doConnect() async {
    try {
      if (_url == null) {
        return false;
      }

      _connectionStateController.add(WebSocketConnectionState.connecting);
      _channel = WebSocketChannel.connect(Uri.parse(_url!));

      _channel!.stream.listen(
        (message) {
          _handleMessage(message);
        },
        onError: (error) {
          print('WebSocket 错误: $error');
          _handleDisconnect();
        },
        onDone: () {
          print('WebSocket 连接关闭');
          _handleDisconnect();
        },
      );

      await Future.delayed(const Duration(milliseconds: 500));

      if (_channel != null) {
        _isConnected = true;
        _reconnectAttempts = 0;
        _connectionStateController.add(WebSocketConnectionState.connected);
        _startHeartbeat();
        print('WebSocket 连接成功: $_url');
        return true;
      } else {
        _connectionStateController.add(WebSocketConnectionState.disconnected);
        return false;
      }
    } catch (e) {
      print('连接失败: $e');
      _connectionStateController.add(WebSocketConnectionState.disconnected);
      _attemptReconnect();
      return false;
    }
  }

  /// 处理消息
  void _handleMessage(dynamic message) {
    try {
      if (message is String) {
        final json = jsonDecode(message) as Map<String, dynamic>;

        // 检查是否是屏幕帧的元数据
        if (json['type'] == 'screenFrame') {
          // 等待下一个二进制消息
          _pendingMetadata = json;
        } else {
          final msg = Message.fromJson(json);
          _messageController.add(msg);
        }
      } else if (message is Uint8List) {
        // 二进制数据（屏幕帧）
        if (_pendingMetadata != null) {
          final msg = Message(
            type: MessageType.screenFrame,
            binaryData: message,
            data: _pendingMetadata!['data'] as Map<String, dynamic>?,
          );
          _pendingMetadata = null;
          _messageController.add(msg);
        }
      }
    } catch (e) {
      print('处理消息失败: $e');
    }
  }

  Map<String, dynamic>? _pendingMetadata;

  /// 发送原始 JSON 文本（不经过 Message 协议封装）
  Future<bool> sendRawJson(Map<String, dynamic> json) async {
    if (!_isConnected || _channel == null) {
      return false;
    }
    try {
      final jsonString = jsonEncode(json);
      print('WebSocketClient: 发送原始 JSON: $jsonString');
      _channel!.sink.add(jsonString);
      return true;
    } catch (e) {
      print('发送原始 JSON 失败: $e');
      return false;
    }
  }

  /// 发送消息
  Future<bool> sendMessage(Message message) async {
    if (!_isConnected || _channel == null) {
      return false;
    }

    try {
      if (message.binaryData != null) {
        _channel!.sink.add(message.binaryData!);
        _channel!.sink.add(message.toJsonString());
      } else {
        _channel!.sink.add(message.toJsonString());
      }
      return true;
    } catch (e) {
      print('发送消息失败: $e');
      return false;
    }
  }

  /// 启动心跳
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    // 控制端每 5 秒发送一次心跳包，保持连接活跃
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
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
    _attemptReconnect();
  }

  /// 尝试重连
  void _attemptReconnect() {
    if (_reconnectAttempts >= maxReconnectAttempts) {
      print('达到最大重连次数，停止重连');
      return;
    }

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(reconnectDelay, () {
      _reconnectAttempts++;
      print('尝试重连 ($_reconnectAttempts/$maxReconnectAttempts)...');
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

    print('WebSocket 已断开连接');
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
