import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class AppStateProvider with ChangeNotifier {
  String _deviceId = '';
  bool _isServiceRunning = false;

  String get deviceId => _deviceId;
  bool get isServiceRunning => _isServiceRunning;

  AppStateProvider() {
    _initializeDeviceId();
  }

  Future<void> _initializeDeviceId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      String? savedDeviceId = prefs.getString('device_id');
      
      if (savedDeviceId == null || savedDeviceId.isEmpty) {
        savedDeviceId = const Uuid().v4();
        await prefs.setString('device_id', savedDeviceId);
      }
      
      _deviceId = savedDeviceId;
      notifyListeners();
    } catch (e) {
      // 如果获取失败，生成临时ID
      _deviceId = const Uuid().v4();
      notifyListeners();
    }
  }

  void setServiceRunning(bool running) {
    _isServiceRunning = running;
    notifyListeners();
  }

  Future<void> regenerateDeviceId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final newDeviceId = const Uuid().v4();
      await prefs.setString('device_id', newDeviceId);
      _deviceId = newDeviceId;
      notifyListeners();
    } catch (e) {
      // 处理错误
    }
  }
}


