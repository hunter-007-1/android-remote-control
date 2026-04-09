import 'dart:async';
import 'package:flutter/services.dart';

/// 屏幕捕获服务
/// 用于与 Android 原生代码通信，实现屏幕捕获功能
class ScreenCaptureService {
  static const MethodChannel _channel = MethodChannel('screen_capture');
  static const EventChannel _eventChannel =
      EventChannel('screen_capture_stream');

  Stream<Uint8List>? _screenStream;
  bool _isCapturing = false;

  /// 是否正在捕获屏幕
  bool get isCapturing => _isCapturing;

  /// 请求屏幕捕获权限
  /// 返回 true 表示权限已授予，false 表示被拒绝
  Future<bool> requestPermission() async {
    try {
      final result = await _channel.invokeMethod<bool>('requestPermission');
      return result ?? false;
    } catch (e) {
      print('请求屏幕捕获权限失败: $e');
      return false;
    }
  }

  /// 开始屏幕捕获
  /// 返回屏幕数据流
  Stream<Uint8List>? startCapture({
    int width = 1080,
    int height = 1920,
    int bitRate = 8000000,
    int frameRate = 30,
  }) {
    if (_isCapturing) {
      return _screenStream;
    }

    try {
      // 关键：先订阅 EventChannel，确保 Android 侧 onListen 已经拿到 sink
      _screenStream =
          _eventChannel.receiveBroadcastStream().map((dynamic event) {
        if (event is Uint8List) {
          return event;
        } else if (event is List) {
          return Uint8List.fromList(event.cast<int>());
        }
        return Uint8List(0);
      });

      // 再启动原生采集（会在需要时触发授权流程）
      _channel.invokeMethod('startCapture', {
        'width': width,
        'height': height,
        'bitRate': bitRate,
        'frameRate': frameRate,
      });

      _isCapturing = true;
      return _screenStream;
    } catch (e) {
      print('开始屏幕捕获失败: $e');
      return null;
    }
  }

  /// 停止屏幕捕获
  Future<void> stopCapture() async {
    if (!_isCapturing) {
      return;
    }

    try {
      await _channel.invokeMethod('stopCapture');
      _isCapturing = false;
      _screenStream = null;
    } catch (e) {
      print('停止屏幕捕获失败: $e');
    }
  }

  /// 获取屏幕信息
  Future<Map<String, dynamic>?> getScreenInfo() async {
    try {
      final result =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('getScreenInfo');
      return result?.cast<String, dynamic>();
    } catch (e) {
      print('获取屏幕信息失败: $e');
      return null;
    }
  }
}
