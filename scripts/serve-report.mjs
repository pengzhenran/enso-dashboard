// 本地静态服务器：用于在浏览器里查看报告（file:// 下的 canvas/链接行为不一致，建议用 http 打开）
// 用法：node scripts/serve-report.mjs [根目录] [端口]
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(process.argv[2] ?? path.join(import.meta.dirname, '..'));
const port = Number(process.argv[3] ?? 8899);
const types = {
  '.html': 'text/html; charset=utf-8',
  '.csv': 'text/csv; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml'
};

http.createServer((req, res) => {
  const url = decodeURIComponent(req.url.split('?')[0]);
  const rel = url === '/' ? 'report/enso_dashboard.html' : url.replace(/^\/+/, '');
  const file = path.resolve(root, rel);
  if (!file.startsWith(root)) { res.writeHead(403).end('forbidden'); return; }
  fs.readFile(file, (err, buf) => {
    if (err) { res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' }).end('not found: ' + rel); return; }
    res.writeHead(200, { 'content-type': types[path.extname(file).toLowerCase()] ?? 'application/octet-stream' });
    res.end(buf);
  });
}).listen(port, '127.0.0.1', () => {
  console.log(`serving ${root}`);
  console.log(`http://127.0.0.1:${port}/  ->  report/enso_dashboard.html`);
});
