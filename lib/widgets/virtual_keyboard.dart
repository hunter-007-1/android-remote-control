import 'package:flutter/material.dart';

/// 虚拟键盘组件
/// 提供 Android 常用按键
class VirtualKeyboard extends StatelessWidget {
  final Function(int keyCode, String action) onKeyPress;

  const VirtualKeyboard({
    super.key,
    required this.onKeyPress,
  });

  // Android 按键码
  static const int KEYCODE_BACK = 4;
  static const int KEYCODE_HOME = 3;
  static const int KEYCODE_MENU = 82;
  static const int KEYCODE_VOLUME_UP = 24;
  static const int KEYCODE_VOLUME_DOWN = 25;
  static const int KEYCODE_POWER = 26;
  static const int KEYCODE_ENTER = 66;
  static const int KEYCODE_DEL = 67;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '虚拟按键',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            // 第一行：返回、Home、菜单
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildKeyButton(
                  icon: Icons.arrow_back,
                  label: '返回',
                  onPressed: () => onKeyPress(KEYCODE_BACK, 'down'),
                ),
                _buildKeyButton(
                  icon: Icons.home,
                  label: 'Home',
                  onPressed: () => onKeyPress(KEYCODE_HOME, 'down'),
                ),
                _buildKeyButton(
                  icon: Icons.menu,
                  label: '菜单',
                  onPressed: () => onKeyPress(KEYCODE_MENU, 'down'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 第二行：音量、电源
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildKeyButton(
                  icon: Icons.volume_up,
                  label: '音量+',
                  onPressed: () => onKeyPress(KEYCODE_VOLUME_UP, 'down'),
                ),
                _buildKeyButton(
                  icon: Icons.volume_down,
                  label: '音量-',
                  onPressed: () => onKeyPress(KEYCODE_VOLUME_DOWN, 'down'),
                ),
                _buildKeyButton(
                  icon: Icons.power_settings_new,
                  label: '电源',
                  onPressed: () => onKeyPress(KEYCODE_POWER, 'down'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 第三行：回车、删除
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildKeyButton(
                  icon: Icons.keyboard_return,
                  label: '回车',
                  onPressed: () => onKeyPress(KEYCODE_ENTER, 'down'),
                ),
                _buildKeyButton(
                  icon: Icons.backspace,
                  label: '删除',
                  onPressed: () => onKeyPress(KEYCODE_DEL, 'down'),
                ),
                const SizedBox(width: 80), // 占位
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKeyButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: 80,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 24),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

