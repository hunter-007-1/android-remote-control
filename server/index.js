const http = require('http');
const WebSocket = require('ws');

const port = process.env.PORT || 8080;

// HTTP服务器用于健康检查
const server = http.createServer((req, res) => {
  // 设置CORS头
  res.setHeader('Access-Control-Allow-Origin', '*');
  
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ 
      status: 'ok', 
      connections: { hosts: hosts.size, clients: clients.size } 
    }));
  } else if (req.url === '/') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('WebSocket Server Running - Remote Control');
  } else if (req.url === '/ws') {
    // WebSocket升级请求
    res.writeHead(400, { 'Content-Type': 'text/plain' });
    res.end('Use WebSocket protocol to connect');
  } else {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not Found');
  }
});

const wss = new WebSocket.Server({ server });

const hosts = new Map();
const clients = new Map();

console.log('WebSocket 中转服务器启动，端口: ' + port);

wss.on('connection', (ws, req) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const role = url.searchParams.get('role');
  const deviceId = url.searchParams.get('id') || 'unknown';
  const targetId = url.searchParams.get('target');
  
  console.log('========== 新连接 ==========');
  console.log('URL:', req.url);
  console.log('role:', role);
  console.log('deviceId:', deviceId);
  console.log('targetId:', targetId);
  console.log('在线: 被控端=' + hosts.size + ', 控制端=' + clients.size);
  
  if (role === 'host') {
    hosts.set(deviceId, ws);
    console.log('被控端已连接: ' + deviceId);
    console.log('当前在线被控端列表:', Array.from(hosts.keys()));
    
    ws.on('message', (data) => {
      const client = clients.get(deviceId);
      if (client && client.readyState === WebSocket.OPEN) {
        client.send(data);
        console.log('[host->client] 转发屏幕帧: ' + data.length + ' bytes');
      }
    });
    
    ws.on('close', () => {
      hosts.delete(deviceId);
      console.log('被控端断开: ' + deviceId);
      const client = clients.get(deviceId);
      if (client && client.readyState === WebSocket.OPEN) {
        client.send(JSON.stringify({ type: 'disconnect', reason: 'host_disconnected' }));
      }
      clients.delete(deviceId);
    });
  } else if (role === 'client') {
    console.log('控制端尝试连接，目标: ' + targetId);
    console.log('在线被控端:', Array.from(hosts.keys()));
    
    if (targetId && hosts.has(targetId)) {
      const host = hosts.get(targetId);
      clients.set(targetId, ws);
      console.log('控制端已连接，绑定到被控端: ' + targetId);
      
      ws.on('message', (data) => {
        if (host && host.readyState === WebSocket.OPEN) {
          host.send(data);
          console.log('[client->host] 转发控制指令: ' + data.toString().substring(0, 100));
        }
      });
      
      ws.on('close', () => {
        clients.delete(targetId);
        console.log('控制端断开，解除与 ' + targetId + ' 的绑定');
      });
      
      ws.send(JSON.stringify({ type: 'connected', targetId: targetId }));
      console.log('已发送连接成功消息给控制端');
    } else {
      console.log('错误：目标设备不存在或未在线');
      ws.send(JSON.stringify({ type: 'error', message: '目标设备不存在或未在线' }));
      ws.close();
    }
  }
  
  ws.on('error', (err) => {
    console.error('WebSocket 错误:', err.message);
  });
});

setInterval(() => {
  console.log('--- 心跳检测 --- 在线: 被控端=' + hosts.size + ', 控制端=' + clients.size);
  for (const [id, ws] of hosts) {
    if (ws.readyState !== WebSocket.OPEN) {
      hosts.delete(id);
      clients.delete(id);
      console.log('清理断开的被控端: ' + id);
    }
  }
  for (const [id, ws] of clients) {
    if (ws.readyState !== WebSocket.OPEN) {
      clients.delete(id);
    }
  }
}, 5000);

server.listen(port, '0.0.0.0', () => {
  console.log('HTTP服务器监听在端口 ' + port);
  console.log('健康检查: /health');
});

console.log('等待连接...');