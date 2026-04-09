const WebSocket = require('ws');

const wss = new WebSocket.Server({ port: 8080 });

let host = null;    // 被控端
let client = null;  // 控制端

console.log('WebSocket 中转服务器启动，端口: 8080');

wss.on('connection', (ws, req) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const role = url.searchParams.get('role');
  const deviceId = url.searchParams.get('id') || 'unknown';
  
  console.log(`新连接: role=${role}, id=${deviceId}`);
  
  if (role === 'host') {
    // 被控端
    host = ws;
    console.log('被控端已连接');
  } else if (role === 'client') {
    // 控制端
    client = ws;
    console.log('控制端已连接');
  }
  
  // 转发消息
  ws.on('message', (data) => {
    // 广播给另一端
    if (role === 'host' && client && client.readyState === WebSocket.OPEN) {
      client.send(data);
      console.log('转发屏幕帧给控制端');
    } else if (role === 'client' && host && host.readyState === WebSocket.OPEN) {
      host.send(data);
      console.log('转发控制指令给被控端');
    }
  });
  
  ws.on('close', () => {
    console.log(`连接断开: role=${role}`);
    if (role === 'host') {
      host = null;
      // 被控端断开，通知控制端
      if (client && client.readyState === WebSocket.OPEN) {
        client.send(JSON.stringify({ type: 'disconnect', reason: 'host_disconnected' }));
      }
    }
    if (role === 'client') {
      client = null;
    }
  });
  
  ws.on('error', (err) => {
    console.error('WebSocket 错误:', err.message);
  });
});

// 心跳检测
setInterval(() => {
  if (host && host.readyState !== WebSocket.OPEN) host = null;
  if (client && client.readyState !== WebSocket.OPEN) client = null;
}, 5000);

console.log('等待连接...');