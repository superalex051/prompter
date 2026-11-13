// Static server for the exported site (out/). Binds 127.0.0.1:4517 only.
// Unknown paths get out/404.html with a real 404 status, like the production host.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { join, extname, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(fileURLToPath(new URL('.', import.meta.url)), '..', 'out');
const HOST = '127.0.0.1';
const PORT = 4517;
const types = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css',
  '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png',
  '.jpg': 'image/jpeg', '.webp': 'image/webp', '.woff2': 'font/woff2', '.txt': 'text/plain',
  '.xml': 'application/xml', '.ico': 'image/x-icon',
};

async function tryRead(path) {
  try { return await readFile(path); } catch { return null; }
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? '/', `http://${HOST}`);
  const rel = normalize(decodeURIComponent(url.pathname)).replace(/^(\.\.[/\\])+/, '');
  let file = join(root, rel);
  if (!file.startsWith(root)) { res.writeHead(400).end(); return; }
  let body = null;
  if (extname(file)) body = await tryRead(file);
  else body = await tryRead(join(file, 'index.html'));
  if (body) {
    const ext = extname(file) || '.html';
    res.writeHead(200, { 'content-type': types[ext] ?? 'application/octet-stream' }).end(body);
    return;
  }
  const notFound = await tryRead(join(root, '404.html'));
  res.writeHead(404, { 'content-type': 'text/html; charset=utf-8' }).end(notFound ?? 'Not found');
});

server.listen(PORT, HOST, () => console.log(`Serving out/ at http://${HOST}:${PORT}`));
