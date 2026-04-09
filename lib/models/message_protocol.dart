import 'dart:convert';
import 'dart:typed_data';

/// 消息类型枚举
enum MessageType {
  // 连接相关
  connect, // 连接请求
  connected, // 连接成功
  disconnect, // 断开连接
  heartbeat, // 心跳

  // 屏幕相关
  screenFrame, // 屏幕帧数据
  screenInfo, // 屏幕信息

  // 控制相关
  touchEvent, // 触摸事件
  keyEvent, // 按键事件
  gestureEvent, // 手势事件
  swipeEvent, // 滑动事件

  // 错误
  error, // 错误消息
}

/// 消息协议
class Message {
  final MessageType type;
  final Map<String, dynamic>? data;
  final Uint8List? binaryData;

  Message({
    required this.type,
    this.data,
    this.binaryData,
  });

  /// 从 JSON 创建消息
  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      type: MessageType.values.firstWhere(
        (e) => e.toString().split('.').last == json['type'],
        orElse: () => MessageType.error,
      ),
      data: json['data'] as Map<String, dynamic>?,
    );
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'type': type.toString().split('.').last,
      'data': data,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
  }

  /// 序列化为字符串
  String toJsonString() {
    return jsonEncode(toJson());
  }

  /// 创建连接消息
  factory Message.connect({required String deviceId, String? deviceName}) {
    return Message(
      type: MessageType.connect,
      data: {
        'deviceId': deviceId,
        'deviceName': deviceName,
      },
    );
  }

  /// 创建连接成功消息
  factory Message.connected({required String deviceId}) {
    return Message(
      type: MessageType.connected,
      data: {
        'deviceId': deviceId,
      },
    );
  }

  /// 创建屏幕帧消息
  factory Message.screenFrame(
    Uint8List imageData, {
    int? width,
    int? height,
    int? frameNumber,
  }) {
    return Message(
      type: MessageType.screenFrame,
      binaryData: imageData,
      data: {
        'width': width,
        'height': height,
        'frameNumber': frameNumber,
      },
    );
  }

  /// 创建屏幕信息消息
  factory Message.screenInfo({
    required int width,
    required int height,
    required int density,
  }) {
    return Message(
      type: MessageType.screenInfo,
      data: {
        'width': width,
        'height': height,
        'density': density,
      },
    );
  }

  /// 创建触摸事件消息
  factory Message.touchEvent({
    required double x,
    required double y,
    required String action, // down, up, move
    int? pointerId,
  }) {
    return Message(
      type: MessageType.touchEvent,
      data: {
        'x': x,
        'y': y,
        'action': action,
        'pointerId': pointerId,
      },
    );
  }

  /// 创建心跳消息
  factory Message.heartbeat() {
    return Message(
      type: MessageType.heartbeat,
      data: {'timestamp': DateTime.now().millisecondsSinceEpoch},
    );
  }

  /// 创建按键事件消息
  factory Message.keyEvent({
    required int keyCode,
    required String action, // down, up
    int? metaState,
  }) {
    return Message(
      type: MessageType.keyEvent,
      data: {
        'keyCode': keyCode,
        'action': action,
        'metaState': metaState,
      },
    );
  }

  /// 创建手势事件消息
  factory Message.gestureEvent({
    required String gestureType, // tap, longPress, swipe, pinch
    Map<String, dynamic>? gestureData,
  }) {
    return Message(
      type: MessageType.gestureEvent,
      data: {
        'gestureType': gestureType,
        ...?gestureData,
      },
    );
  }

  /// 创建错误消息
  factory Message.error(String error) {
    return Message(
      type: MessageType.error,
      data: {'error': error},
    );
  }
}
