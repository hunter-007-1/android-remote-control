import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../widgets/touchable_screen_viewer.dart';
import '../services/websocket_client.dart' as ws
    show WebSocketClient, WebSocketConnectionState;
import '../services/input_service.dart';
import '../models/message_protocol.dart';
import '../providers/app_state_provider.dart';
import '../utils/network_utils.dart';

class ControllerScreen extends StatefulWidget {
  const ControllerScreen({super.key});

  @override
  State<ControllerScreen> createState() => _ControllerScreenState();
}

class _ControllerScreenState extends State<ControllerScreen> {
  final TextEditingController _deviceIdController = TextEditingController();
  late ws.WebSocketClient _webSocketClient;
  bool _isConnecting = false;
  Uint8List? _screenData;
  StreamSubscription<Message>? _messageSubscription;
  StreamSubscription<ws.WebSocketConnectionState>? _connectionSubscription;
  ws.WebSocketConnectionState _connectionState =
      ws.WebSocketConnectionState.disconnected;
  int _framesReceived = 0;

  String get _serverUrl => 'wss://invigorating-embrace.up.railway.app';

  // 视频流中断检测
  Timer? _frameTimeoutTimer;
  DateTime? _lastFrameTime;
  static const Duration _frameTimeout = Duration(seconds: 5);
  bool _isAutoReconnecting = false;

  // 手势识别相关状态（归一化坐标 0~1）
  double? _gestureStartX;
  double? _gestureStartY;
  double? _gestureLastX;
  double? _gestureLastY;
  DateTime? _gestureStartTime;

  // 滑动检测参数
  static const double _swipeThreshold = 20.0; // 滑动触发阈值（像素）
  static const int _maxClickDuration = 300; // 最大点击时间（毫秒）
  static const int _swipeDuration = 500; // 滑动动画持续时间（毫秒）- 提高到500ms以增强识别率

  @override
  void initState() {
    super.initState();
    _webSocketClient = ws.WebSocketClient();
    _setupListeners();
  }

  void _setupListeners() {
    _messageSubscription = _webSocketClient.messageStream.listen((message) {
      _handleMessage(message);
    });

    _connectionSubscription =
        _webSocketClient.connectionStateStream.listen((state) {
      setState(() {
        _connectionState = state;
      });

      // 连接状态变化时，重置帧超时检测
      if (state == ws.WebSocketConnectionState.connected) {
        _resetFrameTimeout();
      } else {
        _cancelFrameTimeout();
      }
    });
  }

  /// 重置帧超时计时器
  void _resetFrameTimeout() {
    _frameTimeoutTimer?.cancel();
    if (_connectionState == ws.WebSocketConnectionState.connected &&
        !_isAutoReconnecting) {
      _frameTimeoutTimer = Timer(_frameTimeout, () {
        _handleFrameTimeout();
      });
    }
  }

  /// 取消帧超时计时器
  void _cancelFrameTimeout() {
    _frameTimeoutTimer?.cancel();
    _frameTimeoutTimer = null;
  }

  /// 处理视频流中断超时
  void _handleFrameTimeout() {
    if (_isAutoReconnecting) {
      return; // 已经在重连中
    }

    print('检测到视频流中断超过 ${_frameTimeout.inSeconds} 秒，尝试自动重连');

    // 检查是否真的没有收到帧（防止误判）
    if (_lastFrameTime != null) {
      final timeSinceLastFrame = DateTime.now().difference(_lastFrameTime!);
      if (timeSinceLastFrame < _frameTimeout) {
        // 实际上有收到帧，重置计时器
        _resetFrameTimeout();
        return;
      }
    }

    // 显示提示
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('视频流中断，正在尝试重连...'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 2),
        ),
      );
    }

    // 自动重连
    _autoReconnect();
  }

  /// 自动重连
  Future<void> _autoReconnect() async {
    if (_isAutoReconnecting) {
      return;
    }

    _isAutoReconnecting = true;
    _cancelFrameTimeout();

    try {
      final targetId = _deviceIdController.text.trim();

      if (targetId.isEmpty) {
        print('无法自动重连：设备ID为空');
        _isAutoReconnecting = false;
        return;
      }

      await _webSocketClient.disconnect();

      await Future.delayed(const Duration(milliseconds: 500));

      final url = '$_serverUrl/?role=client&target=$targetId';
      final success = await _webSocketClient.connect(url);

      if (success) {
        print('自动重连成功');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('重连成功'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 2),
            ),
          );
        }
        _resetFrameTimeout();
      } else {
        print('自动重连失败');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('重连失败，请手动重连'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      print('自动重连时出错: $e');
    } finally {
      _isAutoReconnecting = false;
    }
  }

  void _handleMessage(Message message) {
    switch (message.type) {
      case MessageType.screenFrame:
        setState(() {
          _screenData = message.binaryData;
          _framesReceived++;
          _lastFrameTime = DateTime.now();
        });
        // 重置超时计时器
        _resetFrameTimeout();
        break;
      case MessageType.screenInfo:
        // 更新屏幕信息
        break;
      case MessageType.connected:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('连接成功'),
            backgroundColor: Colors.green,
          ),
        );
        // 连接成功后，设置控制端屏幕尺寸（用于坐标映射）
        _setControllerScreenSize();
        // 重置帧超时检测
        _resetFrameTimeout();
        // 【修复】连接成功后主动发送 connect 消息完成双向握手
        _sendConnectMessage();
        break;
      case MessageType.error:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message.data?['error'] ?? '发生错误'),
            backgroundColor: Colors.red,
          ),
        );
        break;
      default:
        break;
    }
  }

  /// 处理来自 TouchableScreenViewer 的触摸事件
  /// 支持点击和滑动两种手势
  void _handleTouchFromViewer(double x, double y, String action) {
    if (!_webSocketClient.isConnected) {
      print('ControllerScreen: 未连接，忽略触摸事件');
      return;
    }

    // 确保坐标在有效范围内
    final validX = x.clamp(0.0, 1.0);
    final validY = y.clamp(0.0, 1.0);

    switch (action) {
      case 'down':
        // 记录手势起始位置和时间
        _gestureStartX = validX;
        _gestureStartY = validY;
        _gestureLastX = validX;
        _gestureLastY = validY;
        _gestureStartTime = DateTime.now();
        print(
            'ControllerScreen: 手势开始 x=${validX.toStringAsFixed(3)}, y=${validY.toStringAsFixed(3)}');
        break;

      case 'move':
        // 更新当前位置
        if (_gestureStartX != null && _gestureStartY != null) {
          _gestureLastX = validX;
          _gestureLastY = validY;
        }
        break;

      case 'up':
        // 手势结束，判断是点击还是滑动
        _handleGestureEnd();
        // 清理手势状态
        _gestureStartX = null;
        _gestureStartY = null;
        _gestureLastX = null;
        _gestureLastY = null;
        _gestureStartTime = null;
        break;
    }
  }

  /// 处理手势结束，判断是点击还是滑动
  void _handleGestureEnd() {
    if (_gestureStartX == null ||
        _gestureStartY == null ||
        _gestureLastX == null ||
        _gestureLastY == null ||
        _gestureStartTime == null) {
      return;
    }

    // 计算滑动距离（转换为像素进行判断）
    final mediaQuery = MediaQuery.of(context);
    final screenWidth = mediaQuery.size.width;
    final screenHeight = mediaQuery.size.height;

    final deltaX = (_gestureLastX! - _gestureStartX!) * screenWidth;
    final deltaY = (_gestureLastY! - _gestureStartY!) * screenHeight;
    final distance = math.sqrt(deltaX * deltaX + deltaY * deltaY);

    // 计算手势持续时间
    final duration =
        DateTime.now().difference(_gestureStartTime!).inMilliseconds;

    print('ControllerScreen: 手势结束，'
        'start=(${_gestureStartX!.toStringAsFixed(3)}, ${_gestureStartY!.toStringAsFixed(3)}), '
        'end=(${_gestureLastX!.toStringAsFixed(3)}, ${_gestureLastY!.toStringAsFixed(3)}), '
        'delta=(${deltaX.toStringAsFixed(1)}, ${deltaY.toStringAsFixed(1)}), '
        'distance=${distance.toStringAsFixed(1)}px, '
        'duration=${duration}ms');

    // 判断是点击还是滑动
    if (distance < _swipeThreshold && duration < _maxClickDuration) {
      // 视为点击
      print('ControllerScreen: 判定为点击');
      _sendClickEvent(_gestureStartX!, _gestureStartY!);
    } else if (distance >= _swipeThreshold) {
      // 视为滑动
      print('ControllerScreen: 判定为滑动');
      _sendSwipeEvent(
        _gestureStartX!,
        _gestureStartY!,
        _gestureLastX!,
        _gestureLastY!,
      );
    } else {
      print('ControllerScreen: 手势被忽略（距离或时间不足）');
    }
  }

  /// 发送点击事件
  void _sendClickEvent(double x, double y) {
    print('ControllerScreen: 发送 CLICK x=$x, y=$y');

    // 被控端 AccessibilityService 的 performClick 已经处理完整的点击手势
    // 所以只需要发送 down 事件即可
    _webSocketClient.sendMessage(Message.touchEvent(
      x: x,
      y: y,
      action: 'down',
      pointerId: 0,
    ));
  }

  /// 发送滑动事件
  void _sendSwipeEvent(
    double startX,
    double startY,
    double endX,
    double endY,
  ) {
    print(
        'ControllerScreen: 发送 SWIPE start=($startX, $startY) -> end=($endX, $endY), duration=$_swipeDuration');

    // 直接发送 SWIPE 指令（不嵌套在 data 字段中）
    _webSocketClient.sendRawJson({
      'type': 'SWIPE',
      'startX': startX,
      'startY': startY,
      'endX': endX,
      'endY': endY,
      'duration': _swipeDuration,
    }).then((success) {
      print('ControllerScreen: 发送 SWIPE ${success ? "成功" : "失败"}');
    });
  }

  /// 发送虚拟按键事件（按照协议：{ "type": "KEY", "action": "BACK" }）
  void _sendKeyCommand(String action) {
    print('ControllerScreen: 准备发送 KEY action=$action');
    if (!_webSocketClient.isConnected) {
      print('ControllerScreen: 未连接，无法发送 KEY');
      return;
    }
    print('ControllerScreen: 正在发送 KEY action=$action');
    _webSocketClient.sendRawJson({
      'type': 'KEY',
      'action': action,
    }).then((success) {
      print('ControllerScreen: 发送 KEY action=$action ${success ? "成功" : "失败"}');
    }).catchError((error) {
      print('ControllerScreen: 发送 KEY 异常: $error');
    });
  }

  Future<void> _connectToDevice() async {
    final targetId = _deviceIdController.text.trim();

    if (targetId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请输入被控端设备ID'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _isConnecting = true;
    });

    final url = '$_serverUrl/?role=client&target=$targetId';
    final success = await _webSocketClient.connect(url);

    setState(() {
      _isConnecting = false;
    });

    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('连接失败，请检查设备ID是否正确'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _disconnect() async {
    _cancelFrameTimeout();
    await _webSocketClient.disconnect();
    setState(() {
      _screenData = null;
      _framesReceived = 0;
      _lastFrameTime = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已断开连接'),
      ),
    );
  }

  /// 设置控制端屏幕尺寸（用于坐标映射）
  Future<void> _setControllerScreenSize() async {
    try {
      // 获取屏幕物理尺寸（像素）
      final mediaQuery = MediaQuery.of(context);
      final screenWidth = mediaQuery.size.width * mediaQuery.devicePixelRatio;
      final screenHeight = mediaQuery.size.height * mediaQuery.devicePixelRatio;

      await InputService.setControllerScreenSize(
        width: screenWidth.toInt(),
        height: screenHeight.toInt(),
      );

      print('控制端屏幕尺寸已设置: ${screenWidth.toInt()}x${screenHeight.toInt()}');
    } catch (e) {
      print('设置控制端屏幕尺寸失败: $e');
    }
  }

  /// 发送 connect 消息完成双向握手
  Future<void> _sendConnectMessage() async {
    try {
      final provider = Provider.of<AppStateProvider>(context, listen: false);
      final message = Message.connect(
        deviceId: provider.deviceId,
        deviceName: 'Controller',
      );
      final success = await _webSocketClient.sendMessage(message);
      print('ControllerScreen: 发送 connect 消息 ${success ? "成功" : "失败"}');
    } catch (e) {
      print('ControllerScreen: 发送 connect 消息异常: $e');
    }
  }

  @override
  void dispose() {
    _cancelFrameTimeout();
    _messageSubscription?.cancel();
    _connectionSubscription?.cancel();
    _webSocketClient.dispose();
    _deviceIdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 使用状态分离：未连接时显示表单；连接成功后隐藏表单，视频全屏沉浸展示
    final isConnected = _webSocketClient.isConnected;

    return Stack(
      children: [
        // 背景为黑色，提升观感
        Container(color: Colors.black),
        if (!isConnected) ...[
          // 未连接状态：显示连接表单和提示
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Card(
                  elevation: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '连接设置',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _deviceIdController,
                          decoration: InputDecoration(
                            labelText: '被控端设备ID',
                            hintText: '请输入被控端的设备ID',
                            prefixIcon: const Icon(Icons.fingerprint),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            filled: true,
                            fillColor: Colors.grey[50],
                          ),
                          enabled: !_isConnecting,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '在另一台手机的"被控端"界面获取设备ID',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: ElevatedButton(
                            onPressed: _isConnecting ? null : _connectToDevice,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: _isConnecting
                                ? const Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                  Colors.white),
                                        ),
                                      ),
                                      SizedBox(width: 8),
                                      Text('正在连接...'),
                                    ],
                                  )
                                : const Text('连接设备'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(
                child: _buildBottomArea(),
              ),
            ],
          ),
        ] else ...[
          // 已连接状态：视频视图直接 match_parent 全屏显示
          Positioned.fill(
            child: _buildFullScreenVideo(),
          ),
        ],
        // 底部常驻导航栏（桌面、返回、最近任务）
        if (isConnected)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              height: 56,
              color: Colors.black.withOpacity(0.85),
              child: SafeArea(
                top: false,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildNavButton(
                      icon: Icons.home,
                      label: '桌面',
                      onTap: () => _sendKeyCommand('HOME'),
                    ),
                    _buildNavButton(
                      icon: Icons.arrow_back,
                      label: '返回',
                      onTap: () => _sendKeyCommand('BACK'),
                    ),
                    _buildNavButton(
                      icon: Icons.recent_actors,
                      label: '最近',
                      onTap: () => _sendKeyCommand('RECENT'),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 未连接/连接中状态下的底部区域
  Widget _buildBottomArea() {
    if (_webSocketClient.isConnected) {
      // 已连接状态下，这个方法不会被调用（直接使用全屏视图）
      return const SizedBox.shrink();
    }

    if (_connectionState == ws.WebSocketConnectionState.connecting) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              '正在连接到 ${_deviceIdController.text}...',
              style: TextStyle(
                color: Colors.grey[600],
              ),
            ),
          ],
        ),
      );
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.phone_android_outlined,
            size: 64,
            color: Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            '请输入设备IP和端口并连接',
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey[600],
            ),
          ),
        ],
      ),
    );
  }

  /// 已连接状态下的全屏视频视图
  Widget _buildFullScreenVideo() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 顶部状态栏（半透明覆盖在视频上方）
        Container(
          color: Colors.black.withOpacity(0.3),
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.green,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '已连接: ${_deviceIdController.text}',
                  style: const TextStyle(
                    fontSize: 14,
                    color: Colors.white,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Row(
                children: [
                  const Icon(Icons.videocam, size: 14, color: Colors.white70),
                  const SizedBox(width: 4),
                  Text(
                    '帧数: $_framesReceived',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        // 视频区域：直接 match_parent，全屏显示（底部留56像素给导航栏）
        Expanded(
          child: Container(
            margin: const EdgeInsets.only(bottom: 56),
            color: Colors.black,
            child: TouchableScreenViewer(
              imageData: _screenData,
              // BoxFit.contain 等价于 android:scaleType="fitCenter"
              fit: BoxFit.contain,
              onTouch: (x, y, action) {
                _handleTouchFromViewer(x, y, action);
              },
            ),
          ),
        ),
        // 底部轻提示（半透明覆盖）
        Container(
          height: 32,
          margin: const EdgeInsets.only(bottom: 56),
          color: Colors.black.withOpacity(0.3),
          alignment: Alignment.center,
          child: Text(
            _screenData != null ? '直接在画面上点击/滑动进行控制' : '等待屏幕数据...',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
            ),
          ),
        ),
      ],
    );
  }

  /// 底部导航栏按钮（水平布局）
  Widget _buildNavButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 24),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 悬浮面板中的小按钮（保留以便将来扩展使用）
  Widget _buildControlButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: Colors.white, size: 20),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
