import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'screen_capture_service.dart';

/// 屏幕流提供者
/// 管理屏幕捕获状态和数据流
class ScreenStreamProvider with ChangeNotifier {
  final ScreenCaptureService _captureService = ScreenCaptureService();
  StreamSubscription<Uint8List>? _streamSubscription;

  bool _isCapturing = false;
  Uint8List? _currentFrame;
  String? _error;
  Stream<Uint8List>? _frameStream;

  bool get isCapturing => _isCapturing;
  Uint8List? get currentFrame => _currentFrame;
  String? get error => _error;
  Stream<Uint8List>? get frameStream => _frameStream;

  /// 压缩图像数据为JPEG（减少90%传输量）
  Future<Uint8List?> compressFrame(Uint8List rawFrame) async {
    try {
      // 进一步压缩：目标宽度从540降到360
      final codec = await ui.instantiateImageCodec(rawFrame,
          targetWidth: 360, targetHeight: 640);
      final frame = await codec.getNextFrame();
      final image = frame.image;

      // 使用PNG格式（通过降低分辨率减少传输量）
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();

      if (byteData == null) return rawFrame;

      return Uint8List.view(byteData.buffer);
    } catch (e) {
      return rawFrame;
    }
  }

  /// 开始屏幕捕获
  Future<bool> startCapture({
    int width = 1080,
    int height = 1920,
    int bitRate = 8000000,
    int frameRate = 30,
  }) async {
    if (_isCapturing) {
      return true;
    }

    // 请求权限
    final hasPermission = await _captureService.requestPermission();
    if (!hasPermission) {
      _error = '屏幕捕获权限被拒绝';
      notifyListeners();
      return false;
    }

    // 开始捕获
    final stream = _captureService.startCapture(
      width: width,
      height: height,
      bitRate: bitRate,
      frameRate: frameRate,
    );

    if (stream == null) {
      _error = '无法启动屏幕捕获';
      notifyListeners();
      return false;
    }

    _frameStream = stream;
    _streamSubscription = stream.listen(
      (data) {
        _currentFrame = data;
        _error = null;
        notifyListeners();
      },
      onError: (error) {
        _error = error.toString();
        _isCapturing = false;
        notifyListeners();
      },
    );

    _isCapturing = true;
    _error = null;
    notifyListeners();
    return true;
  }

  /// 停止屏幕捕获
  Future<void> stopCapture() async {
    await _streamSubscription?.cancel();
    _streamSubscription = null;
    await _captureService.stopCapture();
    _isCapturing = false;
    _currentFrame = null;
    _frameStream = null;
    notifyListeners();
  }

  @override
  void dispose() {
    stopCapture();
    super.dispose();
  }
}
