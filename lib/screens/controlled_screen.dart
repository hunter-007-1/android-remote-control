import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/app_state_provider.dart';
import '../services/remote_control_service.dart';
import '../services/input_service.dart';
import '../utils/network_utils.dart';

class ControlledScreen extends StatefulWidget {
  const ControlledScreen({super.key});

  @override
  State<ControlledScreen> createState() => _ControlledScreenState();
}

class _ControlledScreenState extends State<ControlledScreen> {
  late RemoteControlService _remoteControlService;
  bool _isStarting = false;
  String? _localIP;

  @override
  void initState() {
    super.initState();
    _remoteControlService = RemoteControlService();
    _remoteControlService.addListener(_onServiceChanged);
    _loadLocalIP();
  }

  void _onServiceChanged() {
    setState(() {});
  }

  Future<void> _loadLocalIP() async {
    final ip = await NetworkUtils.getLocalIP();
    setState(() {
      _localIP = ip;
    });
  }

  @override
  void dispose() {
    _remoteControlService.removeListener(_onServiceChanged);
    _remoteControlService.dispose();
    super.dispose();
  }

  Future<void> _toggleService() async {
    if (_isStarting) return;

    if (_remoteControlService.isRunning) {
      // 停止服务
      await _remoteControlService.stop();
      final provider = Provider.of<AppStateProvider>(context, listen: false);
      provider.setServiceRunning(false);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('服务已停止'),
          backgroundColor: Colors.orange,
        ),
      );
    } else {
      // 【修复】启动服务前检查无障碍服务是否开启
      final a11yStatus = await InputService.checkAccessibilityService();
      final isA11yEnabled = a11yStatus['enabled'] == true ||
          a11yStatus['serviceAvailable'] == true;

      if (!isA11yEnabled) {
        // 无障碍服务未开启，显示引导对话框
        _showAccessibilityServiceGuide();
        return;
      }

      // 启动服务
      setState(() {
        _isStarting = true;
      });

      final success = await _remoteControlService.start();

      setState(() {
        _isStarting = false;
      });

      if (success) {
        final provider = Provider.of<AppStateProvider>(context, listen: false);
        provider.setServiceRunning(true);

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('服务已启动，连接至云端服务器'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 3),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_remoteControlService.error ?? '启动服务失败'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// 显示无障碍服务引导对话框
  void _showAccessibilityServiceGuide() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.accessibility_new, color: Colors.blue),
            SizedBox(width: 8),
            Text('需要无障碍服务权限'),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('为了实现远程控制功能，需要开启无障碍服务。'),
            SizedBox(height: 16),
            Text('开启步骤：', style: TextStyle(fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            Text('1. 点击下方"去设置"按钮'),
            Text('2. 找到"Android远程控制"服务'),
            Text('3. 点击进入并开启服务'),
            Text('4. 返回应用重新启动服务'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              // 跳转到系统无障碍服务设置
              InputService.openAccessibilitySettings();
            },
            child: const Text('去设置'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<AppStateProvider>(context);
    final deviceId = provider.deviceId;

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '设备信息',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Icon(Icons.fingerprint, color: Colors.blue),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '设备ID',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            ),
                            const SizedBox(height: 4),
                            SelectableText(
                              deviceId,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: deviceId));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('设备ID已复制到剪贴板'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '服务状态',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _remoteControlService.isRunning
                              ? Colors.green
                              : Colors.red,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _remoteControlService.isRunning ? '运行中' : '已停止',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: _remoteControlService.isRunning
                              ? Colors.green
                              : Colors.red,
                        ),
                      ),
                    ],
                  ),
                  if (_remoteControlService.isRunning) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Icon(Icons.people, size: 16, color: Colors.grey),
                        const SizedBox(width: 8),
                        Text(
                          '已连接客户端: ${_remoteControlService.connectedClients}',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey[700],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Icon(Icons.videocam,
                            size: 16, color: Colors.grey),
                        const SizedBox(width: 8),
                        Text(
                          '已发送帧数: ${_remoteControlService.framesSent}',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey[700],
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: _isStarting ? null : _toggleService,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _remoteControlService.isRunning
                            ? Colors.red
                            : Colors.green,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: _isStarting
                          ? const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                        Colors.white),
                                  ),
                                ),
                                SizedBox(width: 8),
                                Text('正在启动...'),
                              ],
                            )
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(_remoteControlService.isRunning
                                    ? Icons.stop
                                    : Icons.play_arrow),
                                const SizedBox(width: 8),
                                Text(_remoteControlService.isRunning
                                    ? '停止服务'
                                    : '启动服务'),
                              ],
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          if (_remoteControlService.isRunning)
            Card(
              elevation: 2,
              color: Colors.blue[50],
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  children: [
                    const Icon(
                      Icons.cloud_done,
                      size: 48,
                      color: Colors.blue,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '云端服务运行中',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.wifi, size: 16, color: Colors.blue),
                        const SizedBox(width: 8),
                        Text(
                          _remoteControlService.isWebSocketConnected
                              ? '已连接服务器'
                              : '连接中...',
                          style: const TextStyle(
                            fontSize: 14,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _remoteControlService.connectedClients > 0
                          ? '控制端已连接'
                          : '等待控制端连接...',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[700],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '服务器: wss://invigorating-embrace.up.railway.app',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[600],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
