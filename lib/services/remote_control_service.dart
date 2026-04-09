import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'screen_stream_provider.dart';
import 'websocket_server.dart';
import 'input_service.dart';
import '../models/message_protocol.dart';

/// 远程控制服务（被控端）
/// 整合屏幕捕获和 WebSocket 服务器
class RemoteControlService with ChangeNotifier {
  final ScreenStreamProvider _screenStreamProvider = ScreenStreamProvider();
  final WebSocketServer _webSocketServer = WebSocketServer();

  StreamSubscription<Uint8List>? _screenSubscription;
  StreamSubscription<Message>? _messageSubscription;

  bool _isRunning = false;
  bool _isCapturing = false;
  bool _isServerRunning = false;
  String? _error;
  int _connectedClients = 0;
  int _framesSent = 0;
  bool _isSendingFrame = false; // 是否正在通过 Socket 发送屏幕帧（用于丢帧控制）

  bool get isRunning => _isRunning;
  bool get isCapturing => _isCapturing;
  bool get isServerRunning => _isServerRunning;
  String? get error => _error;
  int get connectedClients => _connectedClients;
  int get framesSent => _framesSent;
  int get serverPort => _webSocketServer.port;

  /// 启动服务
  Future<bool> start({int? port}) async {
    if (_isRunning) {
      return true;
    }

    try {
      // 启动 WebSocket 服务器
      final serverStarted = await _webSocketServer.start(port: port);
      if (!serverStarted) {
        _error = '启动 WebSocket 服务器失败';
        notifyListeners();
        return false;
      }
      _isServerRunning = true;

      // 设置连接断开回调
      _webSocketServer.onConnectionLost = _handleConnectionLost;

      // 监听客户端连接
      _webSocketServer.clientStream.listen((client) {
        _connectedClients = 1;
        notifyListeners();
      });

      // 监听客户端消息
      _messageSubscription = _webSocketServer.messageStream.listen((message) {
        _handleMessage(message);
      });

      // 启动屏幕捕获
      final captureStarted = await _screenStreamProvider.startCapture();
      if (!captureStarted) {
        _error = _screenStreamProvider.error ?? '启动屏幕捕获失败';
        notifyListeners();
        await _webSocketServer.stop();
        _isServerRunning = false;
        return false;
      }
      _isCapturing = true;

      // 直接监听屏幕流，每收到一帧就立即发送（实时传输）
      final frameStream = _screenStreamProvider.frameStream;
      if (frameStream != null) {
        _screenSubscription = frameStream.listen(
          (frameData) {
            if (_isRunning && _webSocketServer.currentClient != null) {
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
        await _webSocketServer.stop();
        _isServerRunning = false;
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

  /// 发送屏幕帧（带丢帧策略）
  Future<void> _sendScreenFrame(Uint8List frameData) async {
    if (_webSocketServer.currentClient == null) {
      return;
    }

    // 丢帧策略：
    // 如果上一帧还在通过 Socket 发送中，说明发送队列中仍有未完成的数据，
    // 此时直接丢弃当前新帧，避免排队导致的“延迟越来越大”和卡顿。
    if (_isSendingFrame) {
      // 如需调试可以在此处打印日志
      return;
    }

    _isSendingFrame = true;
    try {
      final success = await _webSocketServer.sendScreenFrame(
        frameData,
        frameNumber: _framesSent++,
      );
      if (!success) {
        // 发送失败的具体处理已在 WebSocketServer._handleConnectionError 中完成
      }
    } catch (error) {
      print('发送屏幕帧时出错: $error');
    } finally {
      _isSendingFrame = false;
    }
  }

  /// 处理连接断开
  void _handleConnectionLost() {
    print('检测到连接断开，停止录屏并清理资源');
    // 设置错误信息，通知用户
    _error = '连接已断开';
    // 停止服务（会自动清理所有资源）
    stop();
  }

  /// 处理客户端消息
  void _handleMessage(Message message) {
    print('RemoteControlService: 收到消息 type=${message.type}');
    switch (message.type) {
      case MessageType.connect:
        // 发送连接成功消息
        _webSocketServer.sendMessage(Message.connected(
          deviceId: 'device-id', // TODO: 使用实际设备ID
        ));
        break;
      case MessageType.heartbeat:
        // 响应心跳
        _webSocketServer.sendMessage(Message.heartbeat());
        break;
      case MessageType.touchEvent:
        // 处理触摸事件
        _handleTouchEvent(message);
        break;
      case MessageType.keyEvent:
        // 处理按键事件
        _handleKeyEvent(message);
        break;
      case MessageType.swipeEvent:
        // 处理滑动事件
        _handleSwipeEvent(message);
        break;
      case MessageType.error:
        // 可能是自定义JSON指令，尝试解析
        print('RemoteControlService: 收到 error 类型消息，可能是自定义指令');
        _handleRawJsonCommand(message);
        break;
      default:
        print('RemoteControlService: 忽略未知消息类型 ${message.type}');
        break;
    }
  }

  /// 处理原始JSON控制指令（CLICK, SWIPE, KEY等）
  void _handleRawJsonCommand(Message message) {
    final data = message.data;
    print('RemoteControlService: 收到原始指令 data=$data');
    if (data == null) {
      print('RemoteControlService: 指令数据为空，忽略');
      return;
    }

    final type = data['type'] as String?;
    if (type == null) {
      print('RemoteControlService: 指令类型为空，忽略');
      return;
    }

    print('RemoteControlService: 处理指令 type=$type');

    switch (type.toUpperCase()) {
      case 'CLICK':
        final x = data['x'] as double?;
        final y = data['y'] as double?;
        if (x != null && y != null) {
          print(
              'RemoteControlService: 执行 CLICK x=${x.toStringAsFixed(3)}, y=${y.toStringAsFixed(3)}');
          _sendTouchEventToAndroid(x, y, 'down', 0);
          Future.delayed(const Duration(milliseconds: 50), () {
            _sendTouchEventToAndroid(x, y, 'up', 0);
          });
        } else {
          print('RemoteControlService: CLICK 指令坐标无效 x=$x, y=$y');
        }
        break;

      case 'SWIPE':
        final startX = data['startX'] as double?;
        final startY = data['startY'] as double?;
        final endX = data['endX'] as double?;
        final endY = data['endY'] as double?;
        final duration = data['duration'] as int? ?? 500;
        if (startX != null && startY != null && endX != null && endY != null) {
          print(
              'RemoteControlService: 执行 SWIPE start=(${startX.toStringAsFixed(3)}, ${startY.toStringAsFixed(3)}) -> end=(${endX.toStringAsFixed(3)}, ${endY.toStringAsFixed(3)}), duration=$duration');
          _sendSwipeEvent(startX, startY, endX, endY, duration);
        } else {
          print(
              'RemoteControlService: SWIPE 指令坐标无效 startX=$startX, startY=$startY, endX=$endX, endY=$endY');
        }
        break;

      case 'KEY':
        final action = data['action'] as String?;
        if (action != null) {
          print('RemoteControlService: 执行 KEY action=$action');
          _handleKeyCommand(action);
        } else {
          print('RemoteControlService: KEY 指令 action 为空');
        }
        break;

      default:
        print('RemoteControlService: 忽略未知指令 type=$type');
        break;
    }
  }

  /// 发送滑动事件到Android（直接调用AccessibilityService.performSwipe）
  void _sendSwipeEvent(
      double startX, double startY, double endX, double endY, int duration) {
    print('RemoteControlService: 调用 InputService.injectSwipeEvent '
        'start=(${startX.toStringAsFixed(3)}, ${startY.toStringAsFixed(3)}) -> '
        'end=(${endX.toStringAsFixed(3)}, ${endY.toStringAsFixed(3)}), '
        'duration=$duration');

    InputService.injectSwipeEvent(
      startX: startX,
      startY: startY,
      endX: endX,
      endY: endY,
      duration: duration,
    ).then((success) {
      print('RemoteControlService: 滑动事件 ${success ? "成功" : "失败"}');
    }).catchError((error) {
      print('RemoteControlService: 滑动事件异常 $error');
    });
  }

  /// 处理按键命令
  void _handleKeyCommand(String action) {
    print('RemoteControlService: _handleKeyCommand action=$action');
    switch (action.toUpperCase()) {
      case 'BACK':
        print('RemoteControlService: 执行 BACK 按键');
        _sendKeyEventToAndroid(4, 'down', 0);
        Future.delayed(const Duration(milliseconds: 50), () {
          _sendKeyEventToAndroid(4, 'up', 0);
        });
        break;
      case 'HOME':
        print('RemoteControlService: 执行 HOME 按键');
        _sendKeyEventToAndroid(3, 'down', 0);
        Future.delayed(const Duration(milliseconds: 50), () {
          _sendKeyEventToAndroid(3, 'up', 0);
        });
        break;
      case 'RECENT':
        print('RemoteControlService: 执行 RECENT 按键');
        _sendKeyEventToAndroid(187, 'down', 0);
        Future.delayed(const Duration(milliseconds: 50), () {
          _sendKeyEventToAndroid(187, 'up', 0);
        });
        break;
      case 'VOLUME_UP':
        print('RemoteControlService: 执行 VOLUME_UP 按键');
        _sendKeyEventToAndroid(24, 'down', 0);
        Future.delayed(const Duration(milliseconds: 50), () {
          _sendKeyEventToAndroid(24, 'up', 0);
        });
        break;
      case 'VOLUME_DOWN':
        print('RemoteControlService: 执行 VOLUME_DOWN 按键');
        _sendKeyEventToAndroid(25, 'down', 0);
        Future.delayed(const Duration(milliseconds: 50), () {
          _sendKeyEventToAndroid(25, 'up', 0);
        });
        break;
      default:
        print('RemoteControlService: 未知按键 action=$action');
        break;
    }
  }

  /// 处理触摸事件
  void _handleTouchEvent(Message message) {
    final data = message.data;
    print('RemoteControlService: 收到触摸事件消息，data=$data');

    if (data == null) {
      print('RemoteControlService: 触摸事件数据为空');
      return;
    }

    final x = data['x'] as double?;
    final y = data['y'] as double?;
    final action = data['action'] as String?;
    final pointerId = data['pointerId'] as int?;

    print('RemoteControlService: 解析触摸事件 x=$x, y=$y, action=$action');

    if (x != null && y != null && action != null) {
      print('RemoteControlService: 准备发送触摸事件到 Android');
      // 通过 Method Channel 发送到 Android（异步执行，不阻塞）
      _sendTouchEventToAndroid(x, y, action, pointerId);
    } else {
      print('RemoteControlService: 触摸事件参数无效');
    }
  }

  /// 处理按键事件
  void _handleKeyEvent(Message message) {
    final data = message.data;
    if (data == null) return;

    final keyCode = data['keyCode'] as int?;
    final action = data['action'] as String?;
    final metaState = data['metaState'] as int?;

    if (keyCode != null && action != null) {
      // 通过 Method Channel 发送到 Android（异步执行，不阻塞）
      _sendKeyEventToAndroid(keyCode, action, metaState);
    }
  }

  /// 处理滑动事件
  void _handleSwipeEvent(Message message) {
    final data = message.data;
    if (data == null) return;

    final startX = data['startX'] as double?;
    final startY = data['startY'] as double?;
    final endX = data['endX'] as double?;
    final endY = data['endY'] as double?;
    final duration = data['duration'] as int? ?? 500;

    if (startX != null && startY != null && endX != null && endY != null) {
      print(
          'RemoteControlService: 收到滑动事件 start=($startX, $startY) -> end=($endX, $endY), duration=$duration');
      _sendSwipeEvent(startX, startY, endX, endY, duration);
    }
  }

  /// 发送触摸事件到 Android
  void _sendTouchEventToAndroid(
      double x, double y, String action, int? pointerId) {
    // 异步执行，不阻塞消息处理
    InputService.injectTouchEvent(
      x: x,
      y: y,
      action: action,
      pointerId: pointerId,
    ).catchError((error) {
      print('发送触摸事件失败: $error');
      return false;
    });
  }

  /// 发送按键事件到 Android
  void _sendKeyEventToAndroid(int keyCode, String action, int? metaState) {
    print(
        'RemoteControlService: 调用 InputService.injectKeyEvent keyCode=$keyCode, action=$action');
    // 异步执行，不阻塞消息处理
    InputService.injectKeyEvent(
      keyCode: keyCode,
      action: action,
      metaState: metaState,
    ).then((success) {
      print('RemoteControlService: injectKeyEvent 返回结果: $success');
    }).catchError((error) {
      print('RemoteControlService: 发送按键事件失败: $error');
      return false;
    });
  }

  /// 停止服务
  Future<void> stop() async {
    if (!_isRunning) {
      print('服务未运行，无需停止');
      return;
    }

    print('正在停止远程控制服务...');

    // 按顺序清理资源
    // 1. 停止屏幕流订阅
    try {
      await _screenSubscription?.cancel();
      _screenSubscription = null;
      print('屏幕流订阅已取消');
    } catch (e) {
      print('取消屏幕流订阅时出错: $e');
    }

    // 2. 停止屏幕捕获
    try {
      await _screenStreamProvider.stopCapture();
      _isCapturing = false;
      print('屏幕捕获已停止');
    } catch (e) {
      print('停止屏幕捕获时出错: $e');
    }

    // 3. 停止消息订阅
    try {
      await _messageSubscription?.cancel();
      _messageSubscription = null;
      print('消息订阅已取消');
    } catch (e) {
      print('取消消息订阅时出错: $e');
    }

    // 4. 停止 WebSocket 服务器
    try {
      await _webSocketServer.stop();
      _isServerRunning = false;
      print('WebSocket 服务器已停止');
    } catch (e) {
      print('停止 WebSocket 服务器时出错: $e');
    }

    // 5. 重置所有状态标志
    _connectedClients = 0;
    _framesSent = 0;
    _isRunning = false;
    _isCapturing = false;
    _isServerRunning = false;
    _error = null;

    notifyListeners();
    print('远程控制服务已完全停止，所有资源已清理');
  }

  @override
  void dispose() {
    stop();
    _screenStreamProvider.dispose();
    _webSocketServer.dispose();
    super.dispose();
  }
}
