import 'dart:async';
import 'package:flutter/foundation.dart';
import 'screen_stream_provider.dart';
import 'websocket_host_client.dart';
import 'input_service.dart';
import '../models/message_protocol.dart';
import '../config/server_config.dart';

class RemoteControlService with ChangeNotifier {
  final ScreenStreamProvider _screenStreamProvider = ScreenStreamProvider();
  final WebSocketHostClient _webSocketClient = WebSocketHostClient();

  StreamSubscription<Uint8List>? _screenSubscription;
  StreamSubscription<Message>? _messageSubscription;
  StreamSubscription<WebSocketConnectionState>? _connectionSubscription;

  bool _isRunning = false;
  bool _isCapturing = false;
  bool _isConnected = false;
  String? _error;
  int _connectedClients = 0;
  int _framesSent = 0;
  bool _isSendingFrame = false;

  bool get isRunning => _isRunning;
  bool get isCapturing => _isCapturing;
  bool get isServerRunning => _isConnected;
  String? get error => _error;
  int get connectedClients => _connectedClients;
  int get framesSent => _framesSent;
  int get serverPort => 0;
  bool get isWebSocketConnected => _isConnected;

  Future<bool> start({String? deviceId, int? port}) async {
    if (_isRunning) {
      return true;
    }

    try {
      _connectionSubscription =
          _webSocketClient.connectionStateStream.listen((state) {
        if (state == WebSocketConnectionState.connected) {
          _isConnected = true;
          _connectedClients = 1;
        } else if (state == WebSocketConnectionState.disconnected) {
          _isConnected = false;
          _connectedClients = 0;
        }
        notifyListeners();
      });

      _webSocketClient.onConnectionLost = _handleConnectionLost;

      final targetDeviceId =
          deviceId ?? ServerConfig.defaultServerUrl.split('/').last;
      final success = await _webSocketClient.connect(targetDeviceId);

      if (!success) {
        _error = '连接中转服务器失败';
        notifyListeners();
        return false;
      }
      _isConnected = true;

      _messageSubscription = _webSocketClient.messageStream.listen((message) {
        _handleMessage(message);
      });

      final captureStarted = await _screenStreamProvider.startCapture();
      if (!captureStarted) {
        _error = _screenStreamProvider.error ?? '启动屏幕捕获失败';
        notifyListeners();
        await _webSocketClient.disconnect();
        _isConnected = false;
        return false;
      }
      _isCapturing = true;

      final frameStream = _screenStreamProvider.frameStream;
      if (frameStream != null) {
        _screenSubscription = frameStream.listen(
          (frameData) {
            if (_isRunning && _isConnected) {
              _sendScreenFrame(frameData);
            }
          },
          onError: (error) {
            _error = '屏幕捕获错误: $error';
            notifyListeners();
          },
        );
      } else {
        _error = '无法获取屏幕流';
        notifyListeners();
        await _webSocketClient.disconnect();
        _isConnected = false;
        return false;
      }

      _isRunning = true;
      _error = null;
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<void> _sendScreenFrame(Uint8List frameData) async {
    if (!_isConnected) {
      return;
    }

    if (_isSendingFrame) {
      return;
    }

    _isSendingFrame = true;
    try {
      await _webSocketClient.sendScreenFrame(frameData);
      _framesSent++;
    } catch (error) {
      print('发送屏幕帧时出错: $error');
    } finally {
      _isSendingFrame = false;
    }
  }

  void _handleConnectionLost() {
    print('检测到连接断开，停止录屏并清理资源');
    _error = '连接已断开';
    stop();
  }

  void _handleMessage(Message message) {
    print('RemoteControlService: 收到消息 type=${message.type}');
    switch (message.type) {
      case MessageType.connect:
      case MessageType.connected:
      case MessageType.disconnect:
      case MessageType.heartbeat:
      case MessageType.screenInfo:
      case MessageType.screenFrame:
      case MessageType.gestureEvent:
        break;
      case MessageType.touchEvent:
        _handleTouchEvent(message);
        break;
      case MessageType.keyEvent:
        _handleKeyEvent(message);
        break;
      case MessageType.swipeEvent:
        _handleSwipeEvent(message);
        break;
      case MessageType.error:
        _handleRawJsonCommand(message);
        break;
    }
  }

  void _handleRawJsonCommand(Message message) {
    final data = message.data;
    if (data == null) return;

    final type = data['type'] as String?;
    if (type == null) return;

    switch (type.toUpperCase()) {
      case 'CLICK':
        final x = data['x'] as double?;
        final y = data['y'] as double?;
        if (x != null && y != null) {
          _sendTouchEventToAndroid(x, y, 'down', 0);
          Future.delayed(const Duration(milliseconds: 50), () {
            _sendTouchEventToAndroid(x, y, 'up', 0);
          });
        }
        break;

      case 'SWIPE':
        final startX = data['startX'] as double?;
        final startY = data['startY'] as double?;
        final endX = data['endX'] as double?;
        final endY = data['endY'] as double?;
        final duration = data['duration'] as int? ?? 500;
        if (startX != null && startY != null && endX != null && endY != null) {
          _sendSwipeEvent(startX, startY, endX, endY, duration);
        }
        break;

      case 'KEY':
        final action = data['action'] as String?;
        if (action != null) {
          _handleKeyCommand(action);
        }
        break;
    }
  }

  void _sendSwipeEvent(
      double startX, double startY, double endX, double endY, int duration) {
    InputService.injectSwipeEvent(
      startX: startX,
      startY: startY,
      endX: endX,
      endY: endY,
      duration: duration,
    );
  }

  void _handleKeyCommand(String action) {
    switch (action.toUpperCase()) {
      case 'BACK':
        _sendKeyEventToAndroid(4, 'down', 0);
        Future.delayed(const Duration(milliseconds: 50), () {
          _sendKeyEventToAndroid(4, 'up', 0);
        });
        break;
      case 'HOME':
        _sendKeyEventToAndroid(3, 'down', 0);
        Future.delayed(const Duration(milliseconds: 50), () {
          _sendKeyEventToAndroid(3, 'up', 0);
        });
        break;
      case 'RECENT':
        _sendKeyEventToAndroid(187, 'down', 0);
        Future.delayed(const Duration(milliseconds: 50), () {
          _sendKeyEventToAndroid(187, 'up', 0);
        });
        break;
    }
  }

  void _handleTouchEvent(Message message) {
    final data = message.data;
    if (data == null) return;

    final x = data['x'] as double?;
    final y = data['y'] as double?;
    final action = data['action'] as String?;

    if (x != null && y != null && action != null) {
      _sendTouchEventToAndroid(x, y, action, 0);
    }
  }

  void _handleKeyEvent(Message message) {
    final data = message.data;
    if (data == null) return;

    final keyCode = data['keyCode'] as int?;
    final action = data['action'] as String?;

    if (keyCode != null && action != null) {
      _sendKeyEventToAndroid(keyCode, action, 0);
    }
  }

  void _handleSwipeEvent(Message message) {
    final data = message.data;
    if (data == null) return;

    final startX = data['startX'] as double?;
    final startY = data['startY'] as double?;
    final endX = data['endX'] as double?;
    final endY = data['endY'] as double?;
    final duration = data['duration'] as int? ?? 500;

    if (startX != null && startY != null && endX != null && endY != null) {
      _sendSwipeEvent(startX, startY, endX, endY, duration);
    }
  }

  void _sendTouchEventToAndroid(
      double x, double y, String action, int metaState) {
    InputService.injectTouchEvent(x: x, y: y, action: action);
  }

  void _sendKeyEventToAndroid(int keyCode, String action, int metaState) {
    InputService.injectKeyEvent(
        keyCode: keyCode, action: action, metaState: metaState);
  }

  Future<void> stop() async {
    if (!_isRunning) {
      return;
    }

    print('正在停止远程控制服务...');

    try {
      await _screenSubscription?.cancel();
      _screenSubscription = null;
    } catch (e) {
      print('取消屏幕流订阅时出错: $e');
    }

    try {
      await _screenStreamProvider.stopCapture();
      _isCapturing = false;
    } catch (e) {
      print('停止屏幕捕获时出错: $e');
    }

    try {
      await _messageSubscription?.cancel();
      _messageSubscription = null;
    } catch (e) {
      print('取消消息订阅时出错: $e');
    }

    try {
      await _connectionSubscription?.cancel();
      _connectionSubscription = null;
    } catch (e) {
      print('取消连接状态订阅时出错: $e');
    }

    try {
      await _webSocketClient.disconnect();
      _isConnected = false;
    } catch (e) {
      print('断开WebSocket连接时出错: $e');
    }

    _connectedClients = 0;
    _framesSent = 0;
    _isRunning = false;
    _isCapturing = false;
    _error = null;

    notifyListeners();
    print('远程控制服务已完全停止');
  }

  @override
  void dispose() {
    stop();
    _screenStreamProvider.dispose();
    _webSocketClient.dispose();
    super.dispose();
  }
}
