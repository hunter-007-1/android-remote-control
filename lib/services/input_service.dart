import 'package:flutter/services.dart';

/// 输入服务
/// 用于与 Android 原生代码通信，执行触摸和按键事件
class InputService {
  static const MethodChannel _channel = MethodChannel('input_control');

  /// 执行触摸事件
  static Future<bool> injectTouchEvent({
    required double x,
    required double y,
    required String action, // down, up, move
    int? pointerId,
  }) async {
    try {
      final result = await _channel.invokeMethod<bool>('injectTouchEvent', {
        'x': x,
        'y': y,
        'action': action,
        'pointerId': pointerId,
      });
      return result ?? false;
    } catch (e) {
      print('注入触摸事件失败: $e');
      return false;
    }
  }

  /// 执行按键事件
  static Future<bool> injectKeyEvent({
    required int keyCode,
    required String action, // down, up
    int? metaState,
  }) async {
    try {
      print('InputService: 调用 injectKeyEvent keyCode=$keyCode, action=$action');
      final result = await _channel.invokeMethod<bool>('injectKeyEvent', {
        'keyCode': keyCode,
        'action': action,
        'metaState': metaState,
      });
      print('InputService: injectKeyEvent 返回: $result');
      return result ?? false;
    } catch (e) {
      print('InputService: 注入按键事件失败: $e');
      return false;
    }
  }

  /// 设置控制端屏幕尺寸（用于坐标映射）
  static Future<bool> setControllerScreenSize({
    required int width,
    required int height,
  }) async {
    try {
      final result =
          await _channel.invokeMethod<bool>('setControllerScreenSize', {
        'width': width,
        'height': height,
      });
      return result ?? false;
    } catch (e) {
      print('设置控制端屏幕尺寸失败: $e');
      return false;
    }
  }

  /// 设置视频帧尺寸（用于坐标映射）
  /// 重要：控制端看到的视频帧尺寸可能与实际屏幕尺寸不同
  static Future<bool> setVideoFrameSize({
    required int width,
    required int height,
  }) async {
    try {
      final result = await _channel.invokeMethod<bool>('setVideoFrameSize', {
        'width': width,
        'height': height,
      });
      return result ?? false;
    } catch (e) {
      print('设置视频帧尺寸失败: $e');
      return false;
    }
  }

  /// 检查无障碍服务是否启用
  static Future<Map<String, dynamic>> checkAccessibilityService() async {
    try {
      final result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('checkAccessibilityService');
      return Map<String, dynamic>.from(result ?? {'enabled': false});
    } catch (e) {
      print('检查无障碍服务失败: $e');
      return {'enabled': false, 'error': e.toString()};
    }
  }

  /// 打开无障碍服务设置页面
  static Future<bool> openAccessibilitySettings() async {
    try {
      final result = await _channel.invokeMethod<bool>('openAccessibilitySettings');
      return result ?? false;
    } catch (e) {
      print('打开无障碍服务设置失败: $e');
      return false;
    }
  }

  /// 执行滑动事件
  static Future<bool> injectSwipeEvent({
    required double startX,
    required double startY,
    required double endX,
    required double endY,
    required int duration,
  }) async {
    try {
      final result = await _channel.invokeMethod<bool>('injectSwipeEvent', {
        'startX': startX,
        'startY': startY,
        'endX': endX,
        'endY': endY,
        'duration': duration,
      });
      return result ?? false;
    } catch (e) {
      print('注入滑动事件失败: $e');
      return false;
    }
  }
}
