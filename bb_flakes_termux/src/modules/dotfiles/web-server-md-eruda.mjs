import { createServer } from 'node:http';
import { readFile, stat, readdir } from 'node:fs/promises';
import { join, extname } from 'node:path';
import { homedir } from 'node:os';

const PORT = parseInt(process.argv[2] || '8000');
const ROOT = process.argv[3] || process.env.HOME || '.';
const LIB_DIR = join(homedir(), '.local/lib/httpd');

const ERUDA_SCRIPT = `<script src="https://cdn.jsdelivr.net/npm/eruda"></script><script>eruda.init();</script>`;

const MIME = {
  '.html': 'text/html', '.css': 'text/css', '.js': 'application/javascript',
  '.json': 'application/json', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon', '.woff': 'font/woff', '.woff2': 'font/woff2',
  '.ttf': 'font/ttf', '.pdf': 'application/pdf', '.webp': 'image/webp',
  '.mp4': 'video/mp4', '.webm': 'video/webm', '.txt': 'text/plain',
  '.xml': 'text/xml', '.mjs': 'application/javascript',
  '.md': 'text/markdown',
};

function dirListing(urlPath, entries) {
  const rows = entries.map(e => {
    const slash = e.isDir ? '/' : '';
    const href = urlPath === '/' ? `/${e.name}${slash}` : `${urlPath}/${e.name}${slash}`;
    const icon = e.isDir ? '&#128193;' : e.name.endsWith('.md') ? '&#128220;' : '&#128196;';
    return `<tr><td>${icon}</td><td><a href="${href}">${e.name}${slash}</a></td></tr>`;
  }).join('\n');

  return `<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Index of ${urlPath}</title>
<style>
  body{background:#1a1a2e;color:#e0e0e0;font-family:monospace;padding:20px;margin:0}
  h1{color:#e94560;font-size:1.2rem}
  table{border-collapse:collapse;width:100%}
  td{padding:4px 12px}
  a{color:#0f3460;text-decoration:none;color:#56c5ff}
  a:hover{text-decoration:underline;color:#e94560}
  tr:hover{background:rgba(255,255,255,0.05)}
</style></head><body>
<h1>Index of ${urlPath}</h1>
<table>${urlPath !== '/' ? '<tr><td>&#128193;</td><td><a href="../">../</a></td></tr>' : ''}
${rows}</table>
${ERUDA_SCRIPT}
</body></html>`;
}

function markdownPage(urlPath, mdContent) {
  return `<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${urlPath}</title>
<link rel="stylesheet" href="/__lib__/github-markdown-dark.css">
<style>
  body{background:#0d1117;box-sizing:border-box;min-width:200px;max-width:980px;margin:0 auto;padding:45px}
  @media(max-width:767px){body{padding:15px}}
  .markdown-body{background:#0d1117}
  .nav-bar{margin-bottom:16px;padding-bottom:8px;border-bottom:1px solid #30363d;font-family:monospace;font-size:0.85rem}
  .nav-bar a{color:#56c5ff;text-decoration:none}
  .nav-bar a:hover{text-decoration:underline;color:#e94560}
  .nav-bar .sep{color:#484f58;margin:0 4px}
  .raw-link{float:right;color:#8b949e;font-size:0.8rem}
  .raw-link:hover{color:#56c5ff}
</style></head><body class="markdown-body">
<div class="nav-bar">
  ${breadcrumb(urlPath)}
  <a class="raw-link" href="${urlPath}?raw">view raw</a>
</div>
<div id="content"></div>
<script src="/__lib__/marked.min.js"></script>
<script>
  const rawMarkdown = ${JSON.stringify(mdContent)};
  document.getElementById('content').innerHTML = marked.parse(rawMarkdown);
</script>
${ERUDA_SCRIPT}
</body></html>`;
}

function breadcrumb(urlPath) {
  const parts = urlPath.split('/').filter(Boolean);
  let crumbs = '<a href="/">~</a>';
  let href = '';
  for (const part of parts.slice(0, -1)) {
    href += '/' + part;
    crumbs += `<span class="sep">/</span><a href="${href}/">${part}</a>`;
  }
  if (parts.length > 0) {
    crumbs += `<span class="sep">/</span>${parts[parts.length - 1]}`;
  }
  return crumbs;
}

const server = createServer(async (req, res) => {
  try {
    // App-level firewall: reject non-loopback requests
    const ip = req.socket.remoteAddress;
    if (ip !== '127.0.0.1' && ip !== '::1' && ip !== '::ffff:127.0.0.1') {
      res.writeHead(403, { 'content-type': 'text/plain' });
      return res.end('Forbidden');
    }

    const url = new URL(req.url, 'http://localhost');
    const urlPath = decodeURIComponent(url.pathname);

    // Serve lib assets from ~/.local/lib/httpd/
    if (urlPath.startsWith('/__lib__/')) {
      const libFile = urlPath.slice('/__lib__/'.length);
      // Only allow known lib files (no path traversal)
      if (libFile !== 'marked.min.js' && libFile !== 'github-markdown-dark.css') {
        res.writeHead(404, { 'content-type': 'text/plain' });
        return res.end('Not found');
      }
      const libPath = join(LIB_DIR, libFile);
      const data = await readFile(libPath).catch(() => null);
      if (!data) {
        res.writeHead(404, { 'content-type': 'text/plain' });
        return res.end('Lib file not found');
      }
      const ext = extname(libFile).toLowerCase();
      res.writeHead(200, {
        'content-type': MIME[ext] || 'application/octet-stream',
        'cache-control': 'public, max-age=86400',
      });
      return res.end(data);
    }

    const fsPath = join(ROOT, urlPath);
    const info = await stat(fsPath).catch(() => null);

    if (!info) {
      res.writeHead(404, { 'content-type': 'text/plain' });
      return res.end('Not found');
    }

    if (info.isDirectory()) {
      // Try index.html first
      const indexPath = join(fsPath, 'index.html');
      const hasIndex = await stat(indexPath).catch(() => null);

      if (hasIndex) {
        let html = await readFile(indexPath, 'utf8');
        html = html.replace(/<\/body>/i, `${ERUDA_SCRIPT}</body>`);
        res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
        return res.end(html);
      }

      // Directory listing
      const items = await readdir(fsPath, { withFileTypes: true });
      const entries = items
        .filter(d => !d.name.startsWith('.'))
        .map(d => ({ name: d.name, isDir: d.isDirectory() }))
        .sort((a, b) => (b.isDir - a.isDir) || a.name.localeCompare(b.name));

      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      return res.end(dirListing(urlPath, entries));
    }

    // Serve file
    const ext = extname(fsPath).toLowerCase();
    const mime = MIME[ext] || 'application/octet-stream';

    // Markdown rendering
    if (ext === '.md') {
      const mdContent = await readFile(fsPath, 'utf8');
      // ?raw query param serves raw markdown text
      if (url.searchParams.has('raw')) {
        res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' });
        return res.end(mdContent);
      }
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      return res.end(markdownPage(urlPath, mdContent));
    }

    if (ext === '.html') {
      let html = await readFile(fsPath, 'utf8');
      html = html.replace(/<\/body>/i, `${ERUDA_SCRIPT}</body>`);
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      return res.end(html);
    }

    const data = await readFile(fsPath);
    res.writeHead(200, { 'content-type': mime });
    res.end(data);
  } catch (err) {
    res.writeHead(500, { 'content-type': 'text/plain' });
    res.end('Internal error');
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`web-server-md-eruda listening on http://127.0.0.1:${PORT} -> ${ROOT}`);
});
