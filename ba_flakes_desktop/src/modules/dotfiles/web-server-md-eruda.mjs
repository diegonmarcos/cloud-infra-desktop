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

function secretsPage(urlPath, rawContent) {
  return `<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${urlPath}</title>
<style>
  :root{--bg:#1a1a2e;--card:#16213e;--border:#2a3a5e;--text:#e0e0e0;--dim:#8899aa;--accent:#00d68f;--red:#ff6b6b;--mono:'Courier New',Consolas,monospace}
  *{margin:0;padding:0;box-sizing:border-box}
  body{background:var(--bg);color:var(--text);font-family:var(--mono);padding:24px 32px}
  h1{font-size:16px;color:var(--accent);margin-bottom:4px}
  .badge{font-size:10px;color:var(--red);background:rgba(255,107,107,0.15);border:1px solid rgba(255,107,107,0.3);border-radius:3px;padding:2px 6px;letter-spacing:1px;vertical-align:middle}
  .nav{margin-bottom:16px;padding-bottom:8px;border-bottom:1px solid var(--border);font-size:12px}
  .nav a{color:#56c5ff;text-decoration:none}.nav a:hover{text-decoration:underline}
  .nav .sep{color:#484f58;margin:0 4px}
  table{width:100%;border-collapse:collapse;font-size:13px;margin-top:16px}
  td{padding:8px 14px;border:1px solid var(--border);vertical-align:top}
  tr:nth-child(even){background:#1b2a4a}
  tr:hover{background:rgba(0,214,143,0.05);cursor:pointer}
  tr.copied{background:rgba(0,214,143,0.2);transition:background 0.3s}
  .key{font-weight:bold;white-space:nowrap;width:1%;color:var(--dim)}
  .val{word-break:break-all}
  .copy-btn{background:none;border:1px solid var(--border);border-radius:3px;color:var(--dim);cursor:pointer;font-size:14px;padding:2px 6px;margin-left:8px;font-family:var(--mono);transition:all 0.15s}
  .copy-btn:hover{color:var(--accent);border-color:var(--accent);background:rgba(0,214,143,0.1)}
  .copy-btn.ok{color:var(--accent);border-color:var(--accent)}
  .error{color:var(--red);padding:20px}
</style></head><body>
<div class="nav">${breadcrumb(urlPath)} <a style="float:right;color:var(--dim);font-size:11px" href="${urlPath}?raw">view raw</a></div>
<h1>${urlPath.split('/').pop()} <span class="badge">DECRYPTED</span></h1>
<div id="root"></div>
<script>
const raw = ${JSON.stringify(rawContent)};
try {
  const data = JSON.parse(raw);
  const root = document.getElementById('root');
  if (typeof data === 'object' && data !== null && !Array.isArray(data)) {
    const table = document.createElement('table');
    for (const [k, v] of Object.entries(data)) {
      const tr = document.createElement('tr');
      const tdK = document.createElement('td');
      tdK.className = 'key';
      tdK.textContent = k;
      tr.appendChild(tdK);
      const tdV = document.createElement('td');
      tdV.className = 'val';
      tdV.textContent = v === null ? '—' : String(v);
      const btn = document.createElement('button');
      btn.className = 'copy-btn';
      btn.innerHTML = '\\u2398';
      btn.title = 'Copy value';
      btn.onclick = () => {
        navigator.clipboard.writeText(String(v ?? '')).then(() => {
          btn.classList.add('ok'); btn.innerHTML = '\\u2713';
          setTimeout(() => { btn.classList.remove('ok'); btn.innerHTML = '\\u2398'; }, 1500);
        });
      };
      tdV.appendChild(btn);
      tr.appendChild(tdV);
      tr.addEventListener('dblclick', () => {
        navigator.clipboard.writeText(String(v ?? '')).then(() => {
          tr.classList.add('copied');
          setTimeout(() => tr.classList.remove('copied'), 800);
        });
      });
      table.appendChild(tr);
    }
    root.appendChild(table);
  } else {
    root.innerHTML = '<pre style="background:var(--card);padding:16px;border-radius:6px;border:1px solid var(--border);white-space:pre-wrap">' + raw.replace(/</g,'&lt;') + '</pre>';
  }
} catch(e) {
  document.getElementById('root').innerHTML = '<pre style="background:var(--card);padding:16px;border-radius:6px;border:1px solid var(--border);white-space:pre-wrap">' + raw.replace(/</g,'&lt;') + '</pre>';
}
</script>
${ERUDA_SCRIPT}
</body></html>`;
}

function dataPage(urlPath, rawContent, format) {
  const fileName = urlPath.split('/').pop();
  return `<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${urlPath}</title>
<style>
  :root{--bg:#1a1a2e;--card:#16213e;--border:#2a3a5e;--head:#0f3460;--alt:#1b2a4a;--text:#e0e0e0;--dim:#8899aa;--accent:#00d68f;--link:#5bc0eb;--num:#f0a500;--red:#ff6b6b;--mono:'Courier New',Consolas,monospace}
  *{margin:0;padding:0;box-sizing:border-box}
  body{background:var(--bg);color:var(--text);font-family:var(--mono);padding:24px 32px}
  h1{font-size:16px;color:var(--accent);margin-bottom:4px}
  .badge{font-size:10px;color:var(--link);background:rgba(91,192,235,0.15);border:1px solid rgba(91,192,235,0.3);border-radius:3px;padding:2px 6px;letter-spacing:1px;vertical-align:middle;text-transform:uppercase}
  .nav{margin-bottom:16px;padding-bottom:8px;border-bottom:1px solid var(--border);font-size:12px}
  .nav a{color:#56c5ff;text-decoration:none}.nav a:hover{text-decoration:underline}
  .nav .sep{color:#484f58;margin:0 4px}
  .section{margin:20px 0}
  .section h3{font-size:13px;color:var(--link);text-transform:uppercase;letter-spacing:0.5px;margin-bottom:8px}
  table{width:100%;border-collapse:collapse;font-size:12px;margin-bottom:12px}
  thead th{background:var(--head);color:var(--text);padding:8px 12px;text-align:left;font-weight:bold;border:1px solid var(--border);position:sticky;top:0;white-space:nowrap}
  tbody td{padding:6px 12px;border:1px solid var(--border);vertical-align:top;max-width:500px;overflow-wrap:break-word}
  tbody tr:nth-child(even){background:var(--alt)}
  tbody tr:hover{background:rgba(0,214,143,0.05);cursor:pointer}
  tbody tr.copied{background:rgba(0,214,143,0.2);transition:background 0.3s}
  .card{background:var(--card);border:1px solid var(--border);border-radius:6px;padding:14px 18px;margin-bottom:12px}
  .card h4{font-size:13px;color:var(--accent);margin-bottom:8px}
  .val-null{color:#555}.val-num{color:var(--num)}.val-bool-t{color:var(--accent)}.val-bool-f{color:var(--red)}.val-str{color:var(--text)}
  pre.fallback{background:var(--card);padding:16px;border-radius:6px;border:1px solid var(--border);white-space:pre-wrap;word-break:break-all;font-size:12px;overflow:auto;max-height:80vh}
  .copy-btn{background:none;border:1px solid var(--border);border-radius:3px;color:var(--dim);cursor:pointer;font-size:14px;padding:2px 6px;margin-left:8px;font-family:var(--mono);transition:all 0.15s}
  .copy-btn:hover{color:var(--accent);border-color:var(--accent);background:rgba(0,214,143,0.1)}
  .copy-btn.ok{color:var(--accent);border-color:var(--accent)}
</style></head><body>
<div class="nav">${breadcrumb(urlPath)} <a style="float:right;color:var(--dim);font-size:11px" href="${urlPath}?raw">view raw</a></div>
<h1>${fileName} <span class="badge">${format}</span></h1>
<div id="root"></div>
<script>
const raw = ${JSON.stringify(rawContent)};
const format = ${JSON.stringify(format)};

function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;')}

function copyVal(btn, text) {
  navigator.clipboard.writeText(text).then(() => {
    btn.classList.add('ok'); btn.innerHTML='\\u2713';
    setTimeout(()=>{btn.classList.remove('ok');btn.innerHTML='\\u2398'},1500);
  });
}

function renderVal(v) {
  if (v===null||v===undefined) return '<span class="val-null">—</span>';
  if (typeof v==='boolean') return '<span class="'+(v?'val-bool-t':'val-bool-f')+'">'+v+'</span>';
  if (typeof v==='number') return '<span class="val-num">'+v+'</span>';
  if (Array.isArray(v)) {
    if (!v.length) return '<span class="val-null">[]</span>';
    if (typeof v[0]!=='object') return '<span class="val-str">'+esc(v.join(', '))+'</span>';
    return renderArrayTable(v);
  }
  if (typeof v==='object') return '<span class="val-str" style="font-size:11px">'+esc(JSON.stringify(v))+'</span>';
  return '<span class="val-str">'+esc(v)+'</span>';
}

function renderArrayTable(arr) {
  const keys=[...new Set(arr.flatMap(o=>Object.keys(o)))];
  let h='<table><thead><tr>'+keys.map(k=>'<th>'+esc(k)+'</th>').join('')+'</tr></thead><tbody>';
  arr.forEach(obj=>{
    h+='<tr>'+keys.map(k=>'<td>'+renderVal(obj[k])+'</td>').join('')+'</tr>';
  });
  return h+'</tbody></table>';
}

function renderKV(obj, container) {
  const t=document.createElement('table');
  for (const [k,v] of Object.entries(obj)) {
    const tr=document.createElement('tr');
    tr.innerHTML='<td style="font-weight:bold;white-space:nowrap;width:1%;color:var(--dim)">'+esc(k)+'</td><td>'+renderVal(v)+'</td>';
    const btn=document.createElement('button');
    btn.className='copy-btn';btn.innerHTML='\\u2398';btn.title='Copy';
    btn.onclick=()=>copyVal(btn,typeof v==='object'?JSON.stringify(v):String(v??''));
    tr.lastChild.appendChild(btn);
    tr.addEventListener('dblclick',()=>{
      navigator.clipboard.writeText(typeof v==='object'?JSON.stringify(v):String(v??'')).then(()=>{
        tr.classList.add('copied');setTimeout(()=>tr.classList.remove('copied'),800);
      });
    });
    t.appendChild(tr);
  }
  container.appendChild(t);
}

function renderData(data, container) {
  if (Array.isArray(data)) {
    if (data.length && typeof data[0]==='object') {
      container.innerHTML+=renderArrayTable(data);
    } else {
      container.innerHTML+='<pre class="fallback">'+esc(JSON.stringify(data,null,2))+'</pre>';
    }
  } else if (typeof data==='object' && data!==null) {
    const vals=Object.values(data);
    const isFlat=vals.length && vals.every(v=>typeof v!=='object'||v===null);
    if (isFlat) {
      renderKV(data, container);
    } else {
      for (const [key,val] of Object.entries(data)) {
        const sec=document.createElement('div');sec.className='section';
        sec.innerHTML='<h3>'+esc(key)+'</h3>';
        if (Array.isArray(val) && val.length && typeof val[0]==='object') {
          sec.innerHTML+=renderArrayTable(val);
        } else if (typeof val==='object' && val!==null && !Array.isArray(val)) {
          const subKeys=Object.keys(val);
          if (subKeys.length && typeof val[subKeys[0]]==='object' && !Array.isArray(val[subKeys[0]])) {
            subKeys.forEach(sk=>{
              const card=document.createElement('div');card.className='card';
              card.innerHTML='<h4>'+esc(sk)+'</h4>';
              renderKV(val[sk], card);
              sec.appendChild(card);
            });
          } else {
            renderKV(val, sec);
          }
        } else {
          sec.innerHTML+='<p>'+renderVal(val)+'</p>';
        }
        container.appendChild(sec);
      }
    }
  } else {
    container.innerHTML='<pre class="fallback">'+esc(String(data))+'</pre>';
  }
}

try {
  let data;
  if (format==='yaml') {
    // Simple YAML parse: key: value (flat only, nested falls back to raw)
    const lines=raw.split('\\n').filter(l=>l.trim()&&!l.trim().startsWith('#'));
    const obj={};
    let canParse=true;
    for (const line of lines) {
      const m=line.match(/^([\\w][\\w.-]*):\\s*(.*)$/);
      if (m) { let v=m[2].trim(); if(v==='true')v=true;else if(v==='false')v=false;else if(v&&!isNaN(v))v=Number(v);else if((v.startsWith('"')&&v.endsWith('"'))||(v.startsWith("'")&&v.endsWith("'")))v=v.slice(1,-1); obj[m[1]]=v||null; }
      else { canParse=false; break; }
    }
    data = canParse && Object.keys(obj).length ? obj : null;
    if (!data) {
      document.getElementById('root').innerHTML='<pre class="fallback">'+esc(raw)+'</pre>';
    } else {
      renderData(data, document.getElementById('root'));
    }
  } else {
    data = JSON.parse(raw);
    renderData(data, document.getElementById('root'));
  }
} catch(e) {
  document.getElementById('root').innerHTML='<pre class="fallback">'+esc(raw)+'</pre>';
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

    // ── Browse SPA (backward compat) ──
    if (urlPath === '/__browse__' || urlPath === '/__browse__/') {
      return serveBrowse(res, '/');
    }

    // ── API: directory listing ──
    if (urlPath === '/__api__/ls') {
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

      // Serve browse SPA for directory listings
      return serveBrowse(res, urlPath);
    }

    // Serve file
    const ext = extname(fsPath).toLowerCase();
    const mime = guessMime(ext);

    // ?raw query: serve any text file as plain text
    if (url.searchParams.has('raw') && ext !== '.md') {
      const data = await readFile(fsPath, 'utf8').catch(() => null);
      if (data !== null) {
        res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' });
        return res.end(data);
      }
    }

    // Secrets rendering — KV table with copy buttons
    if (fsPath.endsWith('.secrets') || fsPath.endsWith('.secrets.json')) {
      const content = await readFile(fsPath, 'utf8');
      if (url.searchParams.has('raw')) {
        res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' });
        return res.end(content);
      }
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      return res.end(secretsPage(urlPath, content));
    }

    // JSON rendering — structured tables
    if (ext === '.json') {
      const content = await readFile(fsPath, 'utf8');
      if (url.searchParams.has('raw')) {
        res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' });
        return res.end(content);
      }
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      return res.end(dataPage(urlPath, content, 'json'));
    }

    // YAML rendering — parsed to structured tables
    if (ext === '.yaml' || ext === '.yml') {
      const content = await readFile(fsPath, 'utf8');
      if (url.searchParams.has('raw')) {
        res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' });
        return res.end(content);
      }
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      return res.end(dataPage(urlPath, content, 'yaml'));
    }

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
    const finalMime = mime === 'application/octet-stream'
      ? guessMime(ext, data.toString('utf8', 0, Math.min(data.length, 512)))
      : mime;
    res.writeHead(200, { 'content-type': finalMime });
    res.end(data);
  } catch (err) {
    res.writeHead(500, { 'content-type': 'text/plain' });
    res.end('Internal error');
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`web-server-md-eruda listening on http://127.0.0.1:${PORT} -> ${ROOT}`);
});
