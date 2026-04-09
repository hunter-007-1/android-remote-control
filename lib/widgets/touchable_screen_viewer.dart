import 'package:flutter/material.dart';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';

/// 可触摸的屏幕查看器
/// 支持触摸事件捕获和坐标映射
class TouchableScreenViewer extends StatefulWidget {
  final Uint8List? imageData;
  final BoxFit fit;
  final Function(double x, double y, String action)? onTouch;
  final int? screenWidth;
  final int? screenHeight;

  const TouchableScreenViewer({
    super.key,
    this.imageData,
    this.fit = BoxFit.contain,
    this.onTouch,
    this.screenWidth,
    this.screenHeight,
  });

  @override
  State<TouchableScreenViewer> createState() => _TouchableScreenViewerState();
}

class _TouchableScreenViewerState extends State<TouchableScreenViewer> {
  ui.Image? _image;
  Size? _displaySize;
  Size? _imageSize;
  Offset? _lastPosition;
  bool _isPanning = false;
  Offset? _panStartLocal;

  @override
  void didUpdateWidget(TouchableScreenViewer oldWidget) {
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
          _imageSize =
              Size(frame.image.width.toDouble(), frame.image.height.toDouble());
        });
      }
    } catch (e) {
      print('加载图像失败: $e');
    }
  }

  /// 将点击坐标转换为"归一化坐标"（0~1 的百分比）
  Offset? _convertToScreenCoordinates(Offset localPosition) {
    if (_imageSize == null || _displaySize == null || _image == null) {
      return null;
    }

    final imageSize = _imageSize!;
    final displaySize = _displaySize!;

    double scale;
    if (widget.fit == BoxFit.contain) {
      final scaleX = displaySize.width / imageSize.width;
      final scaleY = displaySize.height / imageSize.height;
      scale = scaleX < scaleY ? scaleX : scaleY;
    } else {
      scale = displaySize.width / imageSize.width;
    }

    final displayedWidth = imageSize.width * scale;
    final displayedHeight = imageSize.height * scale;

    final offsetX = (displaySize.width - displayedWidth) / 2.0;
    final offsetY = (displaySize.height - displayedHeight) / 2.0;

    final relativeX = localPosition.dx - offsetX;
    final relativeY = localPosition.dy - offsetY;

    if (relativeX < 0 ||
        relativeY < 0 ||
        relativeX > displayedWidth ||
        relativeY > displayedHeight) {
      return null;
    }

    final normX = relativeX / displayedWidth;
    final normY = relativeY / displayedHeight;

    return Offset(normX, normY);
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _displaySize = Size(constraints.maxWidth, constraints.maxHeight);

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

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) {
            final screenPos = _convertToScreenCoordinates(details.localPosition);
            if (screenPos != null) {
              _lastPosition = screenPos;
              print('TouchableScreenViewer: tapDown -> (${screenPos.dx.toStringAsFixed(3)}, ${screenPos.dy.toStringAsFixed(3)})');
            }
          },
          onTapUp: (details) {
            final screenPos = _convertToScreenCoordinates(details.localPosition);
            if (screenPos != null) {
              print('TouchableScreenViewer: tapUp -> (${screenPos.dx.toStringAsFixed(3)}, ${screenPos.dy.toStringAsFixed(3)})');
              widget.onTouch?.call(screenPos.dx, screenPos.dy, 'down');
              Future.delayed(const Duration(milliseconds: 50), () {
                widget.onTouch?.call(screenPos.dx, screenPos.dy, 'up');
              });
            }
          },
          onPanStart: (details) {
            final screenPos = _convertToScreenCoordinates(details.localPosition);
            if (screenPos == null) return;
            _isPanning = true;
            _panStartLocal = details.localPosition;
            _lastPosition = screenPos;
            print('TouchableScreenViewer: panStart -> (${screenPos.dx.toStringAsFixed(3)}, ${screenPos.dy.toStringAsFixed(3)})');
            widget.onTouch?.call(screenPos.dx, screenPos.dy, 'down');
          },
          onPanUpdate: (details) {
            if (!_isPanning) return;
            final screenPos = _convertToScreenCoordinates(details.localPosition);
            if (screenPos == null) return;
            _lastPosition = screenPos;
            widget.onTouch?.call(screenPos.dx, screenPos.dy, 'move');
          },
          onPanEnd: (details) {
            if (!_isPanning) return;
            _isPanning = false;
            if (_lastPosition != null) {
              print('TouchableScreenViewer: panEnd -> (${_lastPosition!.dx.toStringAsFixed(3)}, ${_lastPosition!.dy.toStringAsFixed(3)})');
              widget.onTouch?.call(_lastPosition!.dx, _lastPosition!.dy, 'up');
            }
            _lastPosition = null;
          },
          child: CustomPaint(
            painter: _ScreenPainter(_image!, widget.fit),
            child: Container(),
          ),
        );
      },
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
