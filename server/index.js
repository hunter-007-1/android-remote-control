const WebSocket = require('ws');

const wss = new WebSocket.Server({ port: 8080 });

const hosts = new Map();
const clients = new Map();

console.log('WebSocket 中转服务器启动，端口: 8080');

wss.on('connection', (ws, req) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const role = url.searchParams.get('role');
  const deviceId = url.searchParams.get('id') || 'unknown';
  const targetId = url.searchParams.get('target');
  
  console.log(`新连接: role=${role}, id=${deviceId}, target=${targetId}`);
  
  if (role === 'host') {
    hosts.set(deviceId, ws);
    console.log(`被控端已连接: ${deviceId}, 当前在线: ${hosts.size}`);
    
    ws.on('message', (data) => {
      const client = clients.get(deviceId);
      if (client && client.readyState === WebSocket.OPEN) {
        client.send(data);
      }
    });
    
    ws.on('close', () => {
      hosts.delete(deviceId);
      console.log(`被控端断开: ${deviceId}`);
      const client = clients.get(deviceId);
      if (client && client.readyState === WebSocket.OPEN) {
        client.send(JSON.stringify({ type: 'disconnect', reason: 'host_disconnected' }));
      }
      clients.delete(deviceId);
    });
  } else if (role === 'client') {
    if (targetId && hosts.has(targetId)) {
      const host = hosts.get(targetId);
      clients.set(targetId, ws);
      console.log(`控制端已连接，绑定到被控端: ${targetId}`);
      
      ws.on('message', (data) => {
        if (host && host.readyState === WebSocket.OPEN) {
          host.send(data);
        }
      });
      
      ws.on('close', () => {
        clients.delete(targetId);
        console.log(`控制端断开，解除与 ${targetId} 的绑定`);
      });
      
      ws.send(JSON.stringify({ type: 'connected', targetId: targetId }));
    } else {
      ws.send(JSON.stringify({ type: 'error', message: '目标设备不存在或未在线' }));
      ws.close();
    }
  }
  
  ws.on('error', (err) => {
    console.error('WebSocket 错误:', err.message);
  });
});

setInterval(() => {
  console.log(`当前在线: 被控端=${hosts.size}, 控制端=${clients.size}`);
  for (const [id, ws] of hosts) {
    if (ws.readyState !== WebSocket.OPEN) {
      hosts.delete(id);
      clients.delete(id);
    }
  }
  for (const [id, ws] of clients) {
    if (ws.readyState !== WebSocket.OPEN) {
      clients.delete(id);
    }
  }
}, 5000);

console.log('等待连接...');