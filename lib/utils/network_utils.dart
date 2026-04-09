import 'dart:io';

/// 网络工具类
class NetworkUtils {
  /// 获取本机 IP 地址
  static Future<String?> getLocalIP() async {
    try {
      for (var interface in await NetworkInterface.list()) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && 
              !addr.isLoopback &&
              interface.name != 'lo') {
            return addr.address;
          }
        }
      }
    } catch (e) {
      print('获取 IP 地址失败: $e');
    }
    return null;
  }

  /// 获取所有可用的 IP 地址
  static Future<List<String>> getAllIPs() async {
    List<String> ips = [];
    try {
      for (var interface in await NetworkInterface.list()) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && 
              !addr.isLoopback) {
            ips.add(addr.address);
          }
        }
      }
    } catch (e) {
      print('获取 IP 地址列表失败: $e');
    }
    return ips;
  }

  /// 构建 WebSocket URL
  static String buildWebSocketUrl(String ip, int port) {
    return 'ws://$ip:$port';
  }
}

