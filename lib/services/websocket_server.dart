import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/message_protocol.dart';

/// WebSocket 服务器
/// 用于被控端，接收控制端连接并发送屏幕数据
class WebSocketServer {
  HttpServer? _server;
  WebSocketChannel? _clientChannel;
  bool _isRunning = false;
  int _port = 8888;

  // 心跳/活动检测：记录最近一次收到消息的时间
  DateTime? _lastMessageTime;
  Timer? _heartbeatMonitorTimer;

  final StreamController<Message> _messageController =
      StreamController<Message>.broadcast();
  final StreamController<WebSocketChannel> _clientController =
      StreamController<WebSocketChannel>.broadcast();

  /// 连接断开回调（当检测到 Broken pipe 或 SocketException 时调用）
  VoidCallback? onConnectionLost;

  bool get isRunning => _isRunning;
  int get port => _port;
  Stream<Message> get messageStream => _messageController.stream;
  Stream<WebSocketChannel> get clientStream => _clientController.stream;
  WebSocketChannel? get currentClient => _clientChannel;

  /// 检查端口是否被占用
  Future<bool> _isPortAvailable(int port) async {
    try {
      // 尝试绑定端口，如果成功则说明端口可用
      final socket = await RawServerSocket.bind(InternetAddress.anyIPv4, port);
      await socket.close();
      return true;
    } catch (e) {
      // 如果绑定失败，说明端口被占用
      return false;
    }
  }

  /// 启动 WebSocket 服务器
  Future<bool> start({int? port}) async {
    if (_isRunning) {
      print('WebSocket 服务器已在运行');
      return true;
    }

    // 先停止旧服务器（如果存在）
    if (_server != null) {
      print('清理旧服务器实例');
      await stop();
    }

    if (port != null) {
      _port = port;
    }

    // 检查端口是否被占用
    final portAvailable = await _isPortAvailable(_port);
    if (!portAvailable) {
      print('端口 $_port 已被占用，尝试强制关闭旧连接');
      // 如果端口被占用，可能是之前的服务器没有完全关闭
      // 尝试再次停止并等待
      await stop();
      await Future.delayed(const Duration(milliseconds: 500));

      // 再次检查
      final portAvailable2 = await _isPortAvailable(_port);
      if (!portAvailable2) {
        print('端口 $_port 仍然被占用，启动失败');
        return false;
      }
    }

    try {
      final handler = webSocketHandler((WebSocketChannel channel) {
        _handleClient(channel);
      });

      final pipeline =
          const Pipeline().addMiddleware(logRequests()).addHandler(handler);

      _server = await shelf_io.serve(
        pipeline,
        InternetAddress.anyIPv4,
        _port,
      );

      _isRunning = true;
      print('WebSocket 服务器已启动，端口: $_port');
      return true;
    } catch (e) {
      print('启动 WebSocket 服务器失败: $e');
      _isRunning = false;
      _server = null;
      return false;
    }
  }

  /// 处理客户端连接
  void _handleClient(WebSocketChannel channel) {
    print('新的客户端连接');

    // 如果已有客户端，断开旧连接
    if (_clientChannel != null) {
      _clientChannel!.sink.close();
    }

    _clientChannel = channel;
    _clientController.add(channel);

    // 主动发送握手消息，便于客户端确认“真正连上服务端”
    // （否则客户端可能在 TCP 层连上但并未完成我们协议层的确认）
    unawaited(sendMessage(Message.connected(deviceId: 'controlled-device')));

    // 初始化最近活动时间
    _lastMessageTime = DateTime.now();

    // 启动心跳监控：如果 15 秒内没有收到任何消息，则认为连接超时
    _heartbeatMonitorTimer?.cancel();
    _heartbeatMonitorTimer =
        Timer.periodic(const Duration(seconds: 5), (timer) {
      if (_clientChannel == null || _lastMessageTime == null) {
        return;
      }
      final diff = DateTime.now().difference(_lastMessageTime!);
      if (diff > const Duration(seconds: 15)) {
        print('心跳超时（超过 15 秒无数据），断开连接');
        try {
          _clientChannel?.sink.close();
        } catch (_) {}
        _handleConnectionError('Heartbeat timeout');
      }
    });

    // 监听客户端消息
    channel.stream.listen(
      (message) {
        try {
          // 每收到一条消息（包括心跳和业务数据），更新最近活动时间
          _lastMessageTime = DateTime.now();
          if (message is String) {
            final json = jsonDecode(message) as Map<String, dynamic>;

            // 检查是否是自定义指令（CLICK, SWIPE, KEY）
            final type = json['type'] as String?;
            if (type != null &&
                ['CLICK', 'SWIPE', 'KEY'].contains(type.toUpperCase())) {
              // 自定义指令，包装为 error 类型传递，让 RemoteControlService 处理
              final action = json['action'] as String?;
              print('WebSocketServer: 收到自定义指令 type=$type, action=$action');
              final msg = Message(
                type: MessageType.error,
                data: json, // 整个 JSON 作为 data
              );
              _messageController.add(msg);
            } else {
              // 标准协议消息
              final msg = Message.fromJson(json);
              _messageController.add(msg);
            }
          }
        } catch (e) {
          print('解析消息失败: $e');
        }
      },
      onError: (error) {
        print('WebSocket 错误: $error');
        _handleConnectionError('WebSocket 错误: $error');
      },
      onDone: () {
        print('客户端断开连接');
        _handleConnectionError('客户端断开连接');
      },
    );
  }

  /// 断开客户端
  void _disconnectClient() {
    if (_clientChannel != null) {
      _clientChannel = null;
    }
    _heartbeatMonitorTimer?.cancel();
    _heartbeatMonitorTimer = null;
  }

  /// 发送消息到客户端
  Future<bool> sendMessage(Message message) async {
    if (_clientChannel == null) {
      return false;
    }

    try {
      if (message.binaryData != null) {
        // 对于二进制数据，先发送元数据，再发送二进制数据
        final metadata = {
          'type': message.type.toString().split('.').last,
          'data': message.data,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'binarySize': message.binaryData!.length,
        };
        _clientChannel!.sink.add(jsonEncode(metadata));
        // 发送二进制数据
        _clientChannel!.sink.add(message.binaryData!);
      } else {
        // 发送文本消息
        _clientChannel!.sink.add(message.toJsonString());
      }
      return true;
    } on SocketException catch (e) {
      print('发送消息失败 - SocketException: $e');
      _handleConnectionError('连接已断开: SocketException');
      return false;
    } on HttpException catch (e) {
      print('发送消息失败 - HttpException: $e');
      _handleConnectionError('连接已断开: HttpException');
      return false;
    } catch (e) {
      // 检查是否是 Broken pipe 错误
      final errorStr = e.toString().toLowerCase();
      if (errorStr.contains('broken pipe') ||
          errorStr.contains('connection reset') ||
          errorStr.contains('connection closed')) {
        print('发送消息失败 - 连接断开: $e');
        _handleConnectionError('连接已断开');
        return false;
      }
      print('发送消息失败: $e');
      return false;
    }
  }

  /// 处理连接错误
  void _handleConnectionError(String reason) {
    print('检测到连接错误: $reason');
    _disconnectClient();
    // 触发连接断开回调，通知上层停止录屏和清理资源
    onConnectionLost?.call();
  }

  /// 发送屏幕帧
  Future<bool> sendScreenFrame(
    Uint8List imageData, {
    int? width,
    int? height,
    int? frameNumber,
  }) async {
    final message = Message.screenFrame(
      imageData,
      width: width,
      height: height,
      frameNumber: frameNumber,
    );
    return sendMessage(message);
  }

  /// 停止服务器
  Future<void> stop() async {
    if (!_isRunning && _server == null) {
      return;
    }

    print('正在停止 WebSocket 服务器...');

    // 1. 先断开所有客户端连接
    _disconnectClient();

    // 2. 关闭服务器（强制关闭，释放端口）
    try {
      if (_server != null) {
        await _server!.close(force: true);
        print('服务器已关闭');
      }
    } catch (e) {
      print('关闭服务器时出错: $e');
    } finally {
      _server = null;
    }

    // 3. 重置状态
    _isRunning = false;
    _clientChannel = null;

    // 4. 等待端口释放（给系统一些时间）
    await Future.delayed(const Duration(milliseconds: 200));

    print('WebSocket 服务器已完全停止，资源已清理');
  }

  void dispose() {
    stop();
    _messageController.close();
    _clientController.close();
  }
}
