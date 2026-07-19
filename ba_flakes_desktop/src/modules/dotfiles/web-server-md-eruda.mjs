import { createServer } from 'node:http';
import { readFile, stat, readdir } from 'node:fs/promises';
import { join, extname } from 'node:path';
import { homedir } from 'node:os';
import process from 'node:process';

const PORT = parseInt(process.argv[2] || '8000');
const ROOT = process.argv[3] || process.env.HOME || '.';
const LIB_DIR = join(homedir(), '.local/lib/httpd');
const VERBOSE = process.env.HTTPD_VERBOSE !== '0';  // default ON; set HTTPD_VERBOSE=0 to silence

const ERUDA_SCRIPT = `<script src="https://cdn.jsdelivr.net/npm/eruda"></script><script>eruda.init();</script>`;

// ── ANSI colours for console (auto-disabled when stdout isn't a TTY) ──────
const TTY = process.stdout.isTTY;
const C = TTY ? {
  dim: '\x1b[2m', reset: '\x1b[0m', bold: '\x1b[1m',
  red: '\x1b[31m', green: '\x1b[32m', yellow: '\x1b[33m',
  blue: '\x1b[34m', magenta: '\x1b[35m', cyan: '\x1b[36m', gray: '\x1b[90m',
} : Object.fromEntries(['dim','reset','bold','red','green','yellow','blue','magenta','cyan','gray'].map(k => [k, '']));

function fmtBytes(n) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1024 / 1024).toFixed(2)} MB`;
}

// Embed JSON content into an inline <script> tag SAFELY. The HTML parser
// closes a <script> on the first `</script>` it sees in the raw stream, so
// any JSON value containing that substring (or U+2028/U+2029, which JS
// treats as line terminators inside string literals) breaks the page.
// Standard fix used by every framework that inlines JSON in HTML.
function safeJsonForScript(value) {
  let s = JSON.stringify(value);
  s = s.replace(/<\/script/gi, '<\\/script');
  s = s.replace(/<!--/g, '<\\!--');
  s = s.split('\u2028').join('\\u2028');
  s = s.split('\u2029').join('\\u2029');
  return s;
}

const MIME = {
  '.html': 'text/html', '.css': 'text/css', '.js': 'application/javascript',
  '.json': 'application/json', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon', '.woff': 'font/woff', '.woff2': 'font/woff2',
  '.ttf': 'font/ttf', '.pdf': 'application/pdf', '.webp': 'image/webp',
  '.mp4': 'video/mp4', '.webm': 'video/webm', '.txt': 'text/plain',
  '.xml': 'text/xml', '.mjs': 'application/javascript',
  '.md': 'text/markdown',
  // Code & config — serve as text so iframes render them
  '.ts': 'text/plain', '.tsx': 'text/plain', '.rs': 'text/plain',
  '.py': 'text/plain', '.sh': 'text/plain', '.fish': 'text/plain',
  '.nix': 'text/plain', '.yaml': 'text/plain', '.yml': 'text/plain',
  '.toml': 'text/plain', '.conf': 'text/plain', '.ini': 'text/plain',
  '.env': 'text/plain', '.log': 'text/plain', '.lock': 'text/plain',
  '.secrets': 'text/plain', '.service': 'text/plain', '.timer': 'text/plain',
  '.sql': 'text/plain', '.graphql': 'text/plain', '.tf': 'text/plain',
  '.scss': 'text/plain', '.less': 'text/plain',
};

// Fallback: if extension not in MIME map, try to detect text vs binary
function guessMime(ext, content) {
  if (MIME[ext]) return MIME[ext];
  // If content is provided and looks like text, serve as text/plain
  if (content && !content.includes('\0')) return 'text/plain';
  return 'application/octet-stream';
}

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
  const rawMarkdown = ${safeJsonForScript(mdContent)};
  document.getElementById('content').innerHTML = marked.parse(rawMarkdown);
</script>
${ERUDA_SCRIPT}
</body></html>`;
}

// ── SvelteKit adapter-static SPA fallback ──────────────────────────────────
// adapter-static's `fallback: '200.html'` is the standard marker a custom
// Node server is expected to serve for any route path that isn't a real
// file — SvelteKit's own client router then takes over from
// location.pathname. See https://svelte.dev/docs/kit/single-page-apps.
// Walk up from the 404'd path to find the nearest project dir (marked by
// containing a 200.html) — this lets ANY prerendered SvelteKit project
// under $ROOT get correct SPA fallback with zero per-project config.
async function findAncestorFallback(rootFsDir, urlPath) {
  let dir = urlPath.replace(/\/[^/]*$/, '') || '/';
  while (true) {
    const candidate = join(rootFsDir, dir, '200.html');
    if (await stat(candidate).catch(() => null)) return { fallbackPath: candidate, projectUrlDir: dir };
    if (dir === '/' || dir === '') return null;
    dir = dir.replace(/\/[^/]*$/, '') || '/';
  }
}

// adapter-static's 200.html always emits ROOT-ABSOLUTE asset paths
// (href="/_app/...") regardless of `paths.relative`, because it must work
// for any unknown route depth. Since this server hosts many projects under
// one root, root-absolute paths resolve against the WRONG (server) root —
// rewrite them to be absolute from the project's own mount directory.
function rewriteFallbackAbsolutePaths(html, projectUrlDir) {
  if (projectUrlDir === '/' || projectUrlDir === '') return html; // already at server root
  return html.replace(/(href|src)="\/(?!\/)/g, `$1="${projectUrlDir}/`);
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

// Unified structured data renderer — exact same logic as cloud-data/index.html
// Handles: .json, .yaml, .secrets — with copy buttons, typed values, cards, tables
function structuredPage(urlPath, rawContent, format) {
  const fileName = urlPath.split('/').pop();
  const isSecret = format === 'secrets';
  const badgeColor = isSecret ? '#ff6b6b' : '#5bc0eb';
  const badgeBg = isSecret ? 'rgba(255,107,107,0.15)' : 'rgba(91,192,235,0.15)';
  const badgeBorder = isSecret ? 'rgba(255,107,107,0.3)' : 'rgba(91,192,235,0.3)';
  const badgeText = isSecret ? 'DECRYPTED' : format.toUpperCase();

  return `<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${urlPath}</title>
<style>
:root{--bg:#1a1a2e;--bg-card:#16213e;--bg-head:#0f3460;--bg-row-alt:#1b2a4a;--border:#2a3a5e;--text:#e0e0e0;--text-dim:#8899aa;--accent:#00d68f;--link:#5bc0eb;--mono:'Courier New',Consolas,monospace}
*{margin:0;padding:0;box-sizing:border-box}
body{background:var(--bg);color:var(--text);font-family:var(--mono);padding:24px 32px}
h2{font-size:18px;color:var(--accent);margin-bottom:20px;padding-bottom:8px;border-bottom:1px solid var(--border)}
.badge{font-size:10px;color:${badgeColor};background:${badgeBg};border:1px solid ${badgeBorder};border-radius:3px;padding:2px 6px;letter-spacing:1px;vertical-align:middle}
.nav{margin-bottom:16px;padding-bottom:8px;border-bottom:1px solid var(--border);font-size:12px}
.nav a{color:var(--link);text-decoration:none}.nav a:hover{text-decoration:underline}
.nav .sep{color:#484f58;margin:0 4px}
.section{margin-bottom:28px}
.section h3{font-size:14px;color:var(--link);margin-bottom:10px;text-transform:uppercase;letter-spacing:0.5px}
table{width:100%;border-collapse:collapse;font-size:12px;margin-bottom:8px}
thead th{background:var(--bg-head);color:var(--text);padding:8px 12px;text-align:left;font-weight:bold;border:1px solid var(--border);position:sticky;top:0;white-space:nowrap}
tbody td{padding:6px 12px;border:1px solid var(--border);vertical-align:top;max-width:400px;overflow-wrap:break-word}
tbody tr:nth-child(even){background:var(--bg-row-alt)}
tbody tr:hover{background:rgba(0,214,143,0.05);cursor:pointer}
tbody tr.row-copied{background:rgba(0,214,143,0.2);transition:background 0.3s}
.card{background:var(--bg-card);border:1px solid var(--border);border-radius:6px;padding:14px 18px;margin-bottom:12px}
.card h4{font-size:13px;color:var(--accent);margin-bottom:8px}
.card table{margin-bottom:0}
.val-array{font-size:11px;color:var(--text-dim)}
.val-object{font-size:11px;color:var(--text-dim);font-style:italic}
.val-null{color:#555}
.val-number{color:#f0a500}
.val-bool-true{color:var(--accent)}
.val-bool-false{color:#ff6b6b}
.copy-btn{background:none;border:1px solid var(--border);border-radius:3px;color:var(--text-dim);cursor:pointer;font-size:14px;padding:2px 6px;margin-left:8px;vertical-align:middle;transition:all 0.15s;font-family:var(--mono)}
.copy-btn:hover{color:var(--accent);border-color:var(--accent);background:rgba(0,214,143,0.1)}
.copy-btn.copied{color:var(--accent);border-color:var(--accent)}
pre.fallback{background:var(--bg-card);padding:16px;border-radius:6px;border:1px solid var(--border);white-space:pre-wrap;word-break:break-all;font-size:12px;overflow:auto;max-height:80vh}
</style></head><body>
<div class="nav">${breadcrumb(urlPath)} <a style="float:right;color:var(--text-dim);font-size:11px" href="${urlPath}?raw">view raw</a></div>
<h2>${fileName} <span class="badge">${badgeText}</span></h2>
<div id="root"></div>
<script>
const raw = ${safeJsonForScript(rawContent)};
const isSecret = ${isSecret};

function escHtml(s) { return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }
function prettyKey(k) { return k.replace(/_/g,' ').replace(/\\b\\w/g,c=>c.toUpperCase()); }

function copyToClipboard(btn, text) {
  navigator.clipboard.writeText(text).then(()=>{
    btn.classList.add('copied'); btn.innerHTML='\\u2713';
    setTimeout(()=>{btn.classList.remove('copied');btn.innerHTML='\\u2398';},1500);
  });
}

document.addEventListener('dblclick',(e)=>{
  const tr=e.target.closest('tbody tr');
  if(!tr)return;
  const cells=tr.querySelectorAll('td');
  if(cells.length<2)return;
  const valCell=cells[1];
  const text=Array.from(valCell.childNodes).filter(n=>!n.classList||!n.classList.contains('copy-btn')).map(n=>n.textContent).join('').trim();
  if(!text)return;
  navigator.clipboard.writeText(text).then(()=>{
    tr.classList.add('row-copied');
    setTimeout(()=>tr.classList.remove('row-copied'),800);
  });
});

function renderValue(val) {
  const span = document.createElement('span');
  if (val===null||val===undefined) { span.className='val-null'; span.textContent='—'; }
  else if (typeof val==='boolean') { span.className=val?'val-bool-true':'val-bool-false'; span.textContent=String(val); }
  else if (typeof val==='number') { span.className='val-number'; span.textContent=String(val); }
  else if (Array.isArray(val)) {
    if (!val.length) { span.className='val-null'; span.textContent='—'; }
    else if (typeof val[0]==='object') return renderArrayTable(val);
    else { span.className='val-array'; span.textContent=val.join(', '); }
  } else if (typeof val==='object') { span.className='val-object'; span.textContent=JSON.stringify(val); }
  else { span.textContent=String(val); }
  return span;
}

function renderArrayTable(arr) {
  if (!arr.length) return document.createTextNode('(empty)');
  if (typeof arr[0]!=='object') { const d=document.createElement('div'); d.className='val-array'; d.textContent=arr.join(', '); return d; }
  const keys=[...new Set(arr.flatMap(obj=>Object.keys(obj)))].filter(k=>k!=='_meta');
  const table=document.createElement('table');
  const thead=document.createElement('thead');
  const hr=document.createElement('tr');
  keys.forEach(k=>{const th=document.createElement('th');th.textContent=prettyKey(k);hr.appendChild(th);});
  thead.appendChild(hr); table.appendChild(thead);
  const tbody=document.createElement('tbody');
  arr.forEach(obj=>{
    const tr=document.createElement('tr');
    keys.forEach(k=>{const td=document.createElement('td');td.appendChild(renderValue(obj[k]));tr.appendChild(td);});
    tbody.appendChild(tr);
  });
  table.appendChild(tbody); return table;
}

function renderKVTable(obj) {
  const table=document.createElement('table');
  const tbody=document.createElement('tbody');
  for (const [k,v] of Object.entries(obj)) {
    const tr=document.createElement('tr');
    const th=document.createElement('td');
    th.innerHTML='<strong>'+escHtml(prettyKey(k))+'</strong>';
    tr.appendChild(th);
    const td=document.createElement('td');
    td.appendChild(renderValue(v));
    // Copy button on every row (secrets + data)
    const btn=document.createElement('button');
    btn.className='copy-btn'; btn.innerHTML='\\u2398'; btn.title='Copy value';
    const rawVal=typeof v==='object'?JSON.stringify(v):String(v??'');
    btn.addEventListener('click',()=>copyToClipboard(btn,rawVal));
    td.appendChild(btn);
    tr.appendChild(td);
    tbody.appendChild(tr);
  }
  table.appendChild(tbody); return table;
}

function renderObjectSections(container, obj) {
  for (const [key,val] of Object.entries(obj)) {
    if (key==='_meta') continue;
    const section=document.createElement('div'); section.className='section';
    const h3=document.createElement('h3'); h3.textContent=prettyKey(key); section.appendChild(h3);
    if (Array.isArray(val)) { section.appendChild(renderArrayTable(val)); }
    else if (typeof val==='object'&&val!==null) {
      const subKeys=Object.keys(val);
      if (subKeys.length&&typeof val[subKeys[0]]==='object'&&!Array.isArray(val[subKeys[0]])) {
        subKeys.forEach(sk=>{
          const card=document.createElement('div'); card.className='card';
          const h4=document.createElement('h4'); h4.textContent=sk; card.appendChild(h4);
          card.appendChild(renderKVTable(val[sk]));
          section.appendChild(card);
        });
      } else { section.appendChild(renderKVTable(val)); }
    } else { const p=document.createElement('p'); p.appendChild(renderValue(val)); section.appendChild(p); }
    container.appendChild(section);
  }
}

function renderData(container, data) {
  if (Array.isArray(data)) { container.appendChild(renderArrayTable(data)); }
  else if (typeof data==='object'&&data!==null) {
    const vals=Object.values(data);
    const isFlat=vals.length&&vals.every(v=>typeof v!=='object'||v===null);
    if (isFlat) { container.appendChild(renderKVTable(data)); }
    else { renderObjectSections(container, data); }
  } else { container.appendChild(document.createTextNode(String(data))); }
}

try {
  let data;
  if (${JSON.stringify(format)}==='yaml') {
    const lines=raw.split('\\n').filter(l=>l.trim()&&!l.trim().startsWith('#'));
    const obj={}; let ok=true;
    for (const line of lines) {
      const m=line.match(/^([\\w][\\w.-]*):\\s*(.*)$/);
      if(m){let v=m[2].trim();if(v==='true')v=true;else if(v==='false')v=false;else if(v&&!isNaN(v))v=Number(v);else if((v.startsWith('"')&&v.endsWith('"'))||(v.startsWith("'")&&v.endsWith("'")))v=v.slice(1,-1);obj[m[1]]=v||null;}
      else{ok=false;break;}
    }
    data=ok&&Object.keys(obj).length?obj:null;
    if(!data){document.getElementById('root').innerHTML='<pre class="fallback">'+escHtml(raw)+'</pre>';}
    else{renderData(document.getElementById('root'),data);}
  } else {
    data=JSON.parse(raw);
    renderData(document.getElementById('root'),data);
  }
} catch(e) {
  document.getElementById('root').innerHTML='<pre class="fallback">'+escHtml(raw)+'</pre>';
}
</script>
${ERUDA_SCRIPT}
</body></html>`;
}

async function serveBrowse(res, initPath) {
  const browsePath = join(LIB_DIR, 'browse.html');
  let html = await readFile(browsePath, 'utf8').catch(() => null);
  if (!html) { res.writeHead(404); return res.end('browse.html not found'); }
  // Inject the initial path so no redirect/hash needed
  html = html.replace('__INIT_PATH__', JSON.stringify(initPath));
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
  return res.end(html);
}

// ── Per-request logging ────────────────────────────────────────────────────
// Captured at request start, finalised on res 'finish'. Emits one line per
// request unless HTTPD_VERBOSE=0. Format:
//   [HH:MM:SS] METHOD STATUS  duration  size  RENDER  /path
function logRequest(req, res, ctx) {
  if (!VERBOSE) return;
  const t0 = process.hrtime.bigint();
  res.on('finish', () => {
    const dur = Number(process.hrtime.bigint() - t0) / 1e6;
    const ts = new Date().toISOString().slice(11, 19);
    const status = res.statusCode;
    const statusColor = status < 300 ? C.green : status < 400 ? C.cyan : status < 500 ? C.yellow : C.red;
    const ip = req.socket.remoteAddress?.replace(/^::ffff:/, '') || '?';
    const size = res.getHeader('content-length') ?? ctx.size ?? 0;
    const ct = (res.getHeader('content-type') || '').toString().split(';')[0] || '-';
    const render = ctx.render || '-';
    console.log(
      `${C.gray}[${ts}]${C.reset} ` +
      `${C.bold}${(req.method || '-').padEnd(4)}${C.reset} ` +
      `${statusColor}${status}${C.reset}  ` +
      `${C.dim}${dur.toFixed(1).padStart(6)}ms${C.reset}  ` +
      `${C.dim}${fmtBytes(Number(size)).padStart(8)}${C.reset}  ` +
      `${C.magenta}${render.padEnd(8)}${C.reset} ` +
      `${C.cyan}${req.url}${C.reset}` +
      (ctx.note ? `  ${C.dim}(${ctx.note})${C.reset}` : '') +
      (ip !== '127.0.0.1' ? `  ${C.dim}from ${ip}${C.reset}` : '')
    );
  });
}

const server = createServer(async (req, res) => {
  // ctx is filled progressively as we route; logRequest reads it on 'finish'
  const ctx = { render: '-', size: 0, note: null };
  logRequest(req, res, ctx);
  try {
    // App-level firewall: reject non-loopback requests
    const ip = req.socket.remoteAddress;
    if (ip !== '127.0.0.1' && ip !== '::1' && ip !== '::ffff:127.0.0.1') {
      ctx.render = 'forbid'; ctx.note = `non-loopback ip=${ip}`;
      res.writeHead(403, { 'content-type': 'text/plain' });
      return res.end('Forbidden');
    }

    const url = new URL(req.url, 'http://localhost');
    const urlPath = decodeURIComponent(url.pathname);

    // ── Browse SPA (backward compat) ──
    if (urlPath === '/__browse__' || urlPath === '/__browse__/') {
      ctx.render = 'browse';
      return serveBrowse(res, '/');
    }

    // ── API: directory listing ──
    if (urlPath === '/__api__/ls') {
      ctx.render = 'api-ls';
      const dirPath = url.searchParams.get('path') || '/';
      const fsDir = join(ROOT, dirPath);
      const info = await stat(fsDir).catch(() => null);
      if (!info || !info.isDirectory()) {
        res.writeHead(404, { 'content-type': 'application/json' });
        return res.end(JSON.stringify({ error: 'Not a directory' }));
      }
      const items = await readdir(fsDir);
      const entries = [];
      for (const name of items) {
        if (name.startsWith('.')) continue;
        const s = await stat(join(fsDir, name)).catch(() => null);
        if (s) entries.push({ name, isDir: s.isDirectory() });
      }
      entries.sort((a, b) => (b.isDir - a.isDir) || a.name.localeCompare(b.name));
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify(entries));
    }

    // ── API: read file ──
    if (urlPath === '/__api__/read') {
      ctx.render = 'api-read';
      const filePath = url.searchParams.get('path') || '/';
      const fsFile = join(ROOT, filePath);
      const info = await stat(fsFile).catch(() => null);
      if (!info || info.isDirectory()) {
        res.writeHead(404, { 'content-type': 'application/json' });
        return res.end(JSON.stringify({ error: 'Not a file' }));
      }
      if (info.size > 5 * 1024 * 1024) {
        res.writeHead(413, { 'content-type': 'application/json' });
        return res.end(JSON.stringify({ error: 'File too large (>5MB)' }));
      }
      const content = await readFile(fsFile, 'utf8').catch(() => null);
      if (content === null) {
        res.writeHead(500, { 'content-type': 'application/json' });
        return res.end(JSON.stringify({ error: 'Cannot read file' }));
      }
      const ext = extname(fsFile).toLowerCase();
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ path: filePath, ext, size: info.size, content }));
    }

    // ── API: search ──
    if (urlPath === '/__api__/search') {
      ctx.render = 'api-search';
      const q = (url.searchParams.get('q') || '').toLowerCase();
      const mode = url.searchParams.get('mode') || 'filename';
      const base = url.searchParams.get('path') || '/';
      if (!q) {
        res.writeHead(200, { 'content-type': 'application/json' });
        return res.end('[]');
      }
      const results = [];
      async function walk(dir, rel) {
        if (results.length > 200) return;
        const names = await readdir(dir).catch(() => []);
        for (const name of names) {
          if (name.startsWith('.')) continue;
          const childRel = rel ? rel + '/' + name : name;
          const childFs = join(dir, name);
          const s = await stat(childFs).catch(() => null);
          if (!s) continue;
          if (s.isDirectory()) {
            if (mode === 'filename' && name.toLowerCase().includes(q)) {
              results.push({ path: childRel, isDir: true });
            }
            await walk(childFs, childRel);
          } else {
            if (mode === 'filename' && name.toLowerCase().includes(q)) {
              results.push({ path: childRel, isDir: false });
            } else if (mode === 'content') {
              const info = await stat(childFs).catch(() => null);
              if (info && info.size < 1024 * 1024) {
                const txt = await readFile(childFs, 'utf8').catch(() => null);
                if (txt && txt.toLowerCase().includes(q)) {
                  results.push({ path: childRel, isDir: false });
                }
              }
            }
          }
        }
      }
      await walk(join(ROOT, base), '');
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify(results));
    }

    // Serve lib assets from ~/.local/lib/httpd/
    if (urlPath.startsWith('/__lib__/')) {
      ctx.render = 'lib';
      const libFile = urlPath.slice('/__lib__/'.length);
      // Only allow known lib files (no path traversal)
      if (!['marked.min.js', 'github-markdown-dark.css', 'browse.html'].includes(libFile)) {
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
        'content-type': guessMime(ext),
        'cache-control': 'public, max-age=86400',
      });
      return res.end(data);
    }

    let fsPath = join(ROOT, urlPath);
    let info = await stat(fsPath).catch(() => null);

    // SvelteKit route paths have no extension (e.g. /scene/demo-day) but
    // prerender to a sibling .html file (scene/demo-day.html) — try that
    // before falling back to the SPA shell.
    if (!info && extname(fsPath) === '') {
      const htmlCandidate = `${fsPath}.html`;
      const htmlInfo = await stat(htmlCandidate).catch(() => null);
      if (htmlInfo) { fsPath = htmlCandidate; info = htmlInfo; }
    }

    if (!info) {
      const fallback = await findAncestorFallback(ROOT, urlPath);
      if (fallback) {
        const html = await readFile(fallback.fallbackPath, 'utf8');
        const rewritten = rewriteFallbackAbsolutePaths(html, fallback.projectUrlDir)
          .replace(/<\/body>/i, `${ERUDA_SCRIPT}</body>`);
        ctx.render = 'spa-fallback'; ctx.note = `200.html @ ${fallback.projectUrlDir}`;
        res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
        return res.end(rewritten);
      }
      ctx.render = 'notfound'; ctx.note = `path missing: ${fsPath}`;
      res.writeHead(404, { 'content-type': 'text/plain' });
      return res.end('Not found');
    }
    ctx.size = info.size || 0;

    if (info.isDirectory()) {
      // Try index.html first
      const indexPath = join(fsPath, 'index.html');
      const hasIndex = await stat(indexPath).catch(() => null);

      if (hasIndex) {
        ctx.render = 'index'; ctx.note = `${join(urlPath, 'index.html')}`;
        let html = await readFile(indexPath, 'utf8');
        // Directory served without a trailing slash (e.g. /dist instead of
        // /dist/) breaks relative asset paths ("./_app/...") used by static
        // SPA builds (SvelteKit adapter-static, Vite, etc.) — the browser
        // resolves "./" against the parent, not this dir. Inject a <base>
        // instead of a redirect so the URL bar keeps exactly what was typed.
        if (!/<base[\s>]/i.test(html)) {
          const dirUrl = urlPath.endsWith('/') ? urlPath : urlPath + '/';
          html = html.replace(/<head(\s[^>]*)?>/i, (m) => `${m}<base href="${dirUrl}">`);
        }
        html = html.replace(/<\/body>/i, `${ERUDA_SCRIPT}</body>`);
        res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
        return res.end(html);
      }

      ctx.render = 'browse-dir';
      return serveBrowse(res, urlPath);
    }

    // Serve file
    const ext = extname(fsPath).toLowerCase();
    const mime = guessMime(ext);

    // ?raw query: serve any text file as plain text
    if (url.searchParams.has('raw') && ext !== '.md') {
      const data = await readFile(fsPath, 'utf8').catch(() => null);
      if (data !== null) {
        ctx.render = 'raw'; ctx.note = `ext=${ext} size=${fmtBytes(info.size)}`;
        res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' });
        return res.end(data);
      }
    }

    const acceptsHtml = (req.headers.accept || '').includes('text/html');
    const wantsRaw = url.searchParams.has('raw');

    // Secrets rendering — KV table with copy buttons
    if ((fsPath.endsWith('.secrets') || fsPath.endsWith('.secrets.json')) && acceptsHtml && !wantsRaw) {
      const content = await readFile(fsPath, 'utf8');
      ctx.render = 'secrets'; ctx.note = `size=${fmtBytes(content.length)}`;
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      return res.end(structuredPage(urlPath, content, 'secrets'));
    }

    if (ext === '.json' && acceptsHtml && !wantsRaw) {
      const content = await readFile(fsPath, 'utf8');
      ctx.render = 'json-html'; ctx.note = `${fmtBytes(content.length)} of JSON → structured HTML`;
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      return res.end(structuredPage(urlPath, content, 'json'));
    }

    if ((ext === '.yaml' || ext === '.yml') && acceptsHtml && !wantsRaw) {
      const content = await readFile(fsPath, 'utf8');
      ctx.render = 'yaml-html'; ctx.note = `${fmtBytes(content.length)} of YAML → structured HTML`;
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      return res.end(structuredPage(urlPath, content, 'yaml'));
    }

    // Markdown rendering
    if (ext === '.md') {
      const mdContent = await readFile(fsPath, 'utf8');
      if (url.searchParams.has('raw')) {
        ctx.render = 'raw-md'; ctx.note = `size=${fmtBytes(mdContent.length)}`;
        res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' });
        return res.end(mdContent);
      }
      ctx.render = 'md-html'; ctx.note = `${fmtBytes(mdContent.length)} → marked.js`;
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      return res.end(markdownPage(urlPath, mdContent));
    }

    if (ext === '.html') {
      let html = await readFile(fsPath, 'utf8');
      html = html.replace(/<\/body>/i, `${ERUDA_SCRIPT}</body>`);
      ctx.render = 'html'; ctx.note = 'eruda injected';
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      return res.end(html);
    }

    const data = await readFile(fsPath);
    const finalMime = mime === 'application/octet-stream'
      ? guessMime(ext, data.toString('utf8', 0, Math.min(data.length, 512)))
      : mime;
    ctx.render = 'static'; ctx.note = `mime=${finalMime} size=${fmtBytes(data.length)}`;
    res.writeHead(200, { 'content-type': finalMime });
    res.end(data);
  } catch (err) {
    ctx.render = 'error'; ctx.note = err && err.message ? err.message : String(err);
    if (VERBOSE) console.error(`${C.red}[error]${C.reset} ${req.url}: ${err && err.stack || err}`);
    res.writeHead(500, { 'content-type': 'text/plain' });
    res.end('Internal error');
  }
});

// ── Startup banner ────────────────────────────────────────────────────────
// Verbose by default. Set HTTPD_VERBOSE=0 to silence per-request logs (banner
// always prints — tells you the server is alive). Tries to surface enough
// context that a developer can debug a startup misconfiguration without
// grep'ing the source.
function startupBanner() {
  const url = `http://127.0.0.1:${PORT}`;
  const lines = [
    '',
    `${C.bold}${C.green}━━━ web-server-md-eruda ━━━${C.reset}`,
    `  ${C.dim}url       ${C.reset}${C.cyan}${url}/${C.reset}`,
    `  ${C.dim}root      ${C.reset}${ROOT}`,
    `  ${C.dim}lib_dir   ${C.reset}${LIB_DIR}`,
    `  ${C.dim}pid       ${C.reset}${process.pid}`,
    `  ${C.dim}node      ${C.reset}${process.version}  ${C.dim}(${process.platform}/${process.arch})${C.reset}`,
    `  ${C.dim}verbose   ${C.reset}${VERBOSE ? C.green + 'on' + C.reset + C.dim + ' (HTTPD_VERBOSE=0 to silence)' + C.reset : C.gray + 'off' + C.reset}`,
    `  ${C.dim}firewall  ${C.reset}loopback only ${C.dim}(127.0.0.1, ::1)${C.reset}`,
    `  ${C.dim}max size  ${C.reset}5 MB ${C.dim}(API /__api__/read)${C.reset}`,
    '',
    `  ${C.bold}routes${C.reset}`,
    `    ${C.cyan}/${C.reset}                                  serve files from ${C.dim}\$ROOT${C.reset}`,
    `    ${C.cyan}/<dir>/${C.reset}                            index.html if present, else SPA browse`,
    `    ${C.cyan}/<route-no-ext>${C.reset}                    <route>.html if present (SvelteKit prerender)`,
    `    ${C.cyan}/<unmatched-under-project>${C.reset}         nearest ancestor 200.html (SvelteKit SPA fallback)`,
    `    ${C.cyan}/<file>.{json,yaml,yml,secrets}${C.reset}    structured HTML render`,
    `    ${C.cyan}/<file>.md${C.reset}                         marked.js render`,
    `    ${C.cyan}/<file>?raw${C.reset}                        plain text passthrough`,
    `    ${C.cyan}/__browse__/${C.reset}                       SPA browser`,
    `    ${C.cyan}/__api__/ls?path=...${C.reset}               directory listing JSON`,
    `    ${C.cyan}/__api__/read?path=...${C.reset}             file content JSON (≤5MB)`,
    `    ${C.cyan}/__api__/search?q=...&mode=filename|content${C.reset}  recursive search`,
    `    ${C.cyan}/__lib__/{marked.min.js,github-markdown-dark.css,browse.html}${C.reset}`,
    '',
    `  ${C.bold}log columns${C.reset}  ${C.dim}timestamp method status duration size render-mode url${C.reset}`,
    `${C.bold}${C.green}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C.reset}`,
    '',
  ];
  console.log(lines.join('\n'));
}

server.listen(PORT, '127.0.0.1', () => {
  startupBanner();
});

// Graceful-shutdown summary (Ctrl-C friendly)
let totalRequests = 0;
server.on('request', () => { totalRequests++; });
function shutdown(sig) {
  console.log(`\n${C.dim}[${new Date().toISOString().slice(11,19)}]${C.reset} ${C.yellow}${sig} received${C.reset} — handled ${C.bold}${totalRequests}${C.reset} request(s); shutting down`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 2000).unref();
}
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
