import 'package:flutter/material.dart';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';

/// 屏幕查看器组件
/// 用于显示接收到的屏幕数据
class ScreenViewer extends StatefulWidget {
  final Uint8List? imageData;
  final BoxFit fit;

  const ScreenViewer({
    super.key,
    this.imageData,
    this.fit = BoxFit.contain,
  });

  @override
  State<ScreenViewer> createState() => _ScreenViewerState();
}

class _ScreenViewerState extends State<ScreenViewer> {
  ui.Image? _image;

  @override
  void didUpdateWidget(ScreenViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.imageData != oldWidget.imageData && widget.imageData != null) {
      _loadImage(widget.imageData!);
    }
  }

  Future<void> _loadImage(Uint8List data) async {
    try {
      final codec = await ui.instantiateImageCodec(data);
      final frame = await codec.getNextFrame();
      if (mounted) {
        setState(() {
          _image = frame.image;
        });
      }
    } catch (e) {
      print('加载图像失败: $e');
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.imageData == null || _image == null) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                '等待屏幕数据...',
                style: TextStyle(color: Colors.grey[400]),
              ),
            ],
          ),
        ),
      );
    }

    return CustomPaint(
      painter: _ScreenPainter(_image!, widget.fit),
      child: Container(),
    );
  }
}

class _ScreenPainter extends CustomPainter {
  final ui.Image image;
  final BoxFit fit;

  _ScreenPainter(this.image, this.fit);

  @override
  void paint(Canvas canvas, Size size) {
    final imageSize = Size(image.width.toDouble(), image.height.toDouble());
    final fittedSize = _applyBoxFit(fit, imageSize, size);
    final rect = _centerRect(fittedSize, size);

    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      rect,
      Paint(),
    );
  }

  @override
  bool shouldRepaint(_ScreenPainter oldDelegate) {
    return oldDelegate.image != image || oldDelegate.fit != fit;
  }

  Size _applyBoxFit(BoxFit fit, Size inputSize, Size outputSize) {
    if (inputSize.height <= 0.0 ||
        inputSize.width <= 0.0 ||
        outputSize.height <= 0.0 ||
        outputSize.width <= 0.0) {
      return Size.zero;
    }

    Size destinationSize = outputSize;
    switch (fit) {
      case BoxFit.fill:
        return destinationSize;
      case BoxFit.contain:
        final double scale = (inputSize.width / inputSize.height <
                destinationSize.width / destinationSize.height)
            ? destinationSize.height / inputSize.height
            : destinationSize.width / inputSize.width;
        return Size(inputSize.width * scale, inputSize.height * scale);
      case BoxFit.cover:
        final double scale = (inputSize.width / inputSize.height >
                destinationSize.width / destinationSize.height)
            ? destinationSize.height / inputSize.height
            : destinationSize.width / inputSize.width;
        return Size(inputSize.width * scale, inputSize.height * scale);
      case BoxFit.fitWidth:
        return Size(destinationSize.width,
            inputSize.height * destinationSize.width / inputSize.width);
      case BoxFit.fitHeight:
        return Size(inputSize.width * destinationSize.height / inputSize.height,
            destinationSize.height);
      case BoxFit.none:
        return inputSize;
      case BoxFit.scaleDown:
        final double scale = (inputSize.width / inputSize.height <
                destinationSize.width / destinationSize.height)
            ? destinationSize.height / inputSize.height
            : destinationSize.width / inputSize.width;
        if (scale > 1.0) return inputSize;
        return Size(inputSize.width * scale, inputSize.height * scale);
    }
  }

  Rect _centerRect(Size inputSize, Size outputSize) {
    final double left = (outputSize.width - inputSize.width) / 2;
    final double top = (outputSize.height - inputSize.height) / 2;
    return Rect.fromLTWH(left, top, inputSize.width, inputSize.height);
  }
}
