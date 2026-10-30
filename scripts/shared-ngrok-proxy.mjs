import http from 'node:http';
import net from 'node:net';
const portFor = (url) => /^\/(api\/(campus(?:\/|-|$)|admin\/campus(?:\/|es|$))|campus(?:\/|$))/.test(url) ? 8090 : 8080;
const server = http.createServer((req, res) => {
  const port = portFor(req.url);
  const path = req.url === '/campus' || req.url === '/campus/' ? '/' : req.url;
  const upstream = http.request({hostname:'127.0.0.1', port, path, method:req.method, headers:req.headers}, reply => {
    res.writeHead(reply.statusCode, reply.headers);
    reply.pipe(res);
  });
  upstream.on('error', () => { if (!res.headersSent) res.writeHead(502); res.end('Service unavailable'); });
  req.on('aborted', () => upstream.destroy());
  req.pipe(upstream);
});
server.on('upgrade', (req, socket, head) => {
  const upstream = net.connect(portFor(req.url), '127.0.0.1', () => {
    upstream.write(`${req.method} ${req.url} HTTP/${req.httpVersion}\r\n`);
    for (let i=0;i<req.rawHeaders.length;i+=2) upstream.write(`${req.rawHeaders[i]}: ${req.rawHeaders[i+1]}\r\n`);
    upstream.write('\r\n');
    if (head.length) upstream.write(head);
    socket.pipe(upstream).pipe(socket);
  });
  upstream.on('error', () => socket.destroy());
  socket.on('error', () => upstream.destroy());
  socket.on('close', () => upstream.destroy());
});
server.listen(8079, '127.0.0.1', () => console.log('Bank and campus proxy listening on 127.0.0.1:8079'));
