import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

      if (savedDeviceId == null ||
          savedDeviceId.isEmpty ||
          savedDeviceId.length > 10) {
        final random = DateTime.now().millisecondsSinceEpoch;
        final deviceNum = (random % 900000) + 100000;
        savedDeviceId = deviceNum.toString();
        await prefs.setString('device_id', savedDeviceId);
        print('Generated new 6-digit device ID: $savedDeviceId');
      }

      _deviceId = savedDeviceId;
      notifyListeners();
    } catch (e) {
      final random = DateTime.now().millisecondsSinceEpoch;
      final deviceNum = (random % 900000) + 100000;
      _deviceId = deviceNum.toString();
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
      final random = DateTime.now().millisecondsSinceEpoch;
      final deviceNum = (random % 900000) + 100000;
      final newDeviceId = deviceNum.toString();
      await prefs.setString('device_id', newDeviceId);
      _deviceId = newDeviceId;
      notifyListeners();
    } catch (e) {}
  }
}
