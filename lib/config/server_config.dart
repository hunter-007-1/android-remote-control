/// 服务器配置
/// 修改这里的地址为你的 Railway 部署地址
class ServerConfig {
  /// WebSocket 服务器地址
  /// 格式: ws://域名:端口 或 wss://域名 (HTTPS)
  /// 例如: wss://your-app.up.railway.app
  static const String defaultServerUrl =
      'wss://invigorating-embrace.up.railway.app';

  /// 服务器端口
  static const int defaultPort = 8080;
}
