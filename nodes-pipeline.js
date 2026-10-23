// nodes-pipeline.js - региона-дамп Happ.exe -> накопительный пул узлов -> companion-xray.json + nodes-index.json
// + автосинхронизация upstreams happ-node-* в bridge.settings.json
//
// Разбор: основной путь - массивы "outbounds": [...] внутри JSON-конфигов, которые Happ держит в памяти.
// (Раньше искали объекты по шаблону {"protocol" - это пропускало конфиги, где protocol не первый ключ.)
// Резерв: одиночные объекты {"protocol"...} на случай неполных массивов.
//
// usage: node nodes-pipeline.js [regions.bin]
// dump:  happ-scan.ps1 -Exe Happ -Needle '"outbounds"' -OutFile C:\Temp\opencode\happ-outbounds.bin
const fs = require('fs');
const path = require('path');

const SRC = process.argv[2] || 'C:/Temp/opencode/happ-outbounds.bin';
const PROJ = __dirname;
const OUT_CFG = path.join(PROJ, 'companion-xray.json');
const OUT_IDX = path.join(PROJ, 'nodes-index.json');
const POOL = path.join(PROJ, 'nodes-pool.json');
const BRIDGE_CFG = path.join(PROJ, 'bridge.settings.json');
const PORT_BASE = 10901;

const COMPAT = new Set(['vless', 'vmess', 'trojan', 'shadowsocks']);

// --- регионы ---
const buf = fs.readFileSync(SRC);
const regions = [];
{
  const HDR = Buffer.from('===REGION base=0x');
  const END = Buffer.from('\n===ENDREGION===');
  let pos = 0;
  while ((pos = buf.indexOf(HDR, pos)) >= 0) {
    const hdrEnd = buf.indexOf('\n', pos);
    const endIdx = buf.indexOf(END, hdrEnd);
    if (endIdx < 0) break;
    regions.push(buf.slice(hdrEnd + 1, endIdx).toString('utf8'));
    pos = endIdx + END.length;
  }
}
if (!regions.length) { console.error('не найдено регионов в ' + SRC); process.exit(2); }
console.log('источник:', SRC);
console.log('регионов:', regions.length, '| текст:', (regions.reduce((a, r) => a + r.length, 0) / 1048576).toFixed(1), 'MB');

function takeJson(text, at) {
  let depth = 0, inStr = false, esc = false, start = -1;
  for (let i = at; i < text.length; i++) {
    const c = text[i];
    if (inStr) {
      if (esc) esc = false;
      else if (c === '\\') esc = true;
      else if (c === '"') inStr = false;
      continue;
    }
    if (c === '"') { inStr = true; continue; }
    if (c === '{' || c === '[') { if (start < 0) start = i; depth++; continue; }
    if (c === '}' || c === ']') {
      depth--;
      if (depth === 0 && start >= 0) {
        try { return { ok: true, v: JSON.parse(text.slice(start, i + 1)), end: i }; } catch { return { ok: false, end: i }; }
      }
    }
  }
  return { ok: false, end: -1 };
}

function cleanStream(st) {
  if (!st) return null;
  const out = {};
  if (st.network) out.network = st.network;
  if (st.security) out.security = st.security;
  if (st.tlsSettings) {
    const t = st.tlsSettings, o = {};
    if (t.serverName) o.serverName = t.serverName;
    if (t.fingerprint) o.fingerprint = t.fingerprint;
    if (t.alpn) o.alpn = t.alpn;
    if (t.allowInsecure !== undefined) o.allowInsecure = t.allowInsecure;
    o.show = false;
    out.tlsSettings = o;
  }
  if (st.realitySettings) {
    const r = st.realitySettings, o = {};
    o.show = r.show !== undefined ? r.show : false;
    if (r.fingerprint) o.fingerprint = r.fingerprint;
    if (r.serverName) o.serverName = r.serverName;
    if (r.publicKey) o.publicKey = r.publicKey;
    if (r.shortId) o.shortId = r.shortId;
    if (r.spiderX) o.spiderX = r.spiderX;
    out.realitySettings = o;
  }
  for (const k of ['wsSettings', 'grpcSettings', 'httpSettings', 'xhttpSettings', 'sockopt', 'tcpSettings']) {
    if (st[k]) out[k] = st[k];
  }
  return Object.keys(out).length ? out : null;
}

function normCountry(raw) {
  return String(raw)
    .replace(/[\u{1F1E6}-\u{1F1FF}]/gu, '')
    .replace(/\([^)]*\)/g, '')
    .replace(/[^\p{L}\p{N}\s.\-]/gu, '')
    .replace(/\s+/g, ' ')
    .trim();
}

// --- пул (если есть) ---
let pool = { updated: null, nodes: [] };
if (fs.existsSync(POOL)) {
  try { pool = JSON.parse(fs.readFileSync(POOL, 'utf8').replace(/^\uFEFF/, '')); } catch (e) { console.log('пул повреждён - начинаю новый:', e.message); }
}
const byKey = new Map(pool.nodes.map(n => [n.key, n]));
const before = byKey.size;

// --- сбор ---
let arrays = 0, arraysOk = 0, singles = 0, added = 0, rejected = 0, revived = 0;

function markSeen(key) {
  const existing = byKey.get(key);
  if (existing && existing.dead === true) {
    existing.dead = false; // a fresh Happ scan proves the node still exists; geo re-checks it
    revived++;
  }
}

function addNode(obj, nearText, nearPos) {
  const prot = obj.protocol;
  if (!COMPAT.has(prot)) return;
  const s = obj.settings || {};
  let addr, port;
  if (s.vnext) { addr = s.vnext[0] && s.vnext[0].address; port = s.vnext[0] && s.vnext[0].port; }
  else if (s.servers) { addr = s.servers[0] && s.servers[0].address; port = s.servers[0] && s.servers[0].port; }
  else return;
  if (!addr || !port) return;
  if (/^%/.test(addr) || /^tcp:\/\//.test(addr) || /[\s\uFFFD]/.test(addr) || addr.length > 120) { rejected++; return; }
  const stream = cleanStream(obj.streamSettings);
  const net = (stream && stream.network) || 'tcp';
  const sec = (stream && stream.security) || 'none';
  const key = `${prot}|${addr}|${port}|${net}|${sec}`;
  if (byKey.has(key)) { markSeen(key); return; }
  let name = '', country = '';
  if (nearText && nearPos >= 0) {
    const reR = /"remarks"\s*:\s*"([^"]{1,160})"/g;
    reR.lastIndex = nearPos;
    const rm = reR.exec(nearText);
    if (rm && rm.index - nearPos < 4096) { name = rm[1]; country = normCountry(rm[1]); }
  }
  if (!name) {
    const hm = addr.match(/edge-node([0-9a-z]+)/i);
    name = hm ? `Узел edge-node${hm[1]}` : `Узел ${addr}`;
  }
  byKey.set(key, { key, proto: prot, addr, port: +port, net, sec, country, name, settings: s, stream });
  added++;
}

for (const text of regions) {
  // 1) массивы outbounds
  const reA = /"outbounds"\s*:\s*\[/g;
  let m;
  while ((m = reA.exec(text))) {
    arrays++;
    const at = text.indexOf('[', m.index);
    const res = takeJson(text, at);
    if (!res.ok || !Array.isArray(res.v)) continue;
    arraysOk++;
    for (const o of res.v) if (o && typeof o === 'object' && o.protocol) addNode(o, text, res.end);
  }
  // 2) одиночные объекты (резерв)
  const reO = /\{\s*"protocol"\s*:\s*"([a-z0-9]+)"/g;
  while ((m = reO.exec(text))) {
    singles++;
    const res = takeJson(text, m.index);
    if (!res.ok) continue;
    addNode(res.v, text, res.end);
  }
}

// 3) salvage: конфиг в памяти бывает затёрт повторным использованием кучи (отдельные символы
//    испорчены), поэтому полный JSON не парсится. Достаём поля по отдельности, строго требуя
//    критичные: UUID пользователя + publicKey (для reality). Всё сомнительное отбрасываем.
let salvaged = 0;
const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
for (const text of regions) {
  const reAddr = /"address"\s*:\s*"([^"\s]{3,120})"/g;
  const hits = [];
  let a;
  while ((a = reAddr.exec(text))) hits.push({ pos: a.index, addr: a[1] });
  for (let i = 0; i < hits.length; i++) {
    const { pos, addr: rawAddr } = hits[i];
    if (/^(127\.0\.0\.1|localhost)/i.test(rawAddr) || /^tcp:\/\//.test(rawAddr)) continue;
    if (/[\uFFFD\s]/.test(rawAddr)) continue;
    let addr = rawAddr;
    // типовое искажение домена подписки: proxenserver-.com / proxenserverX.com
    addr = addr.replace(/proxenserver[^.]*\.com$/i, 'proxenservers.com');
    if (!(/^[A-Za-z0-9.-]+$/.test(addr) && (/^(\d{1,3}\.){3}\d{1,3}$/.test(addr) || /\.[A-Za-z]{2,}$/.test(addr)))) continue;
    const winStart = pos, winEnd = i + 1 < hits.length ? hits[i + 1].pos : Math.min(text.length, pos + 3000);
    const win = text.slice(winStart, winEnd);
    const back = text.slice(Math.max(0, pos - 1200), pos);
    const pm = back.match(/"protoco.{0,2}"\s*:\s*"([a-z.]+)"/) || back.match(/"protocol"\s*:\s*"([a-z0-9]+)"/);
    let proto = pm ? pm[1].replace(/\./g, '') : '';
    if (proto === 'vess' || proto === 'vless' || /^v.{0,3}ss$/.test(proto)) proto = 'vless';
    if (!COMPAT.has(proto)) continue;
    const portM = win.match(/"port"\s*:\s*(\d{1,5})/);
    if (!portM) continue;
    const port = +portM[1];
    if (!port || port > 65535) continue;
    const idM = win.match(/"id"\s*:\s*"([^"]{30,40})"/);
    if (!idM || !UUID_RE.test(idM[1])) continue;
    const pbkM = win.match(/"publicKey"\s*:\s*"([A-Za-z0-9_.-]{40,60})"/);
    const snM = win.match(/"serverName"\s*:\s*"([^"]{3,120})"/);
    // имена ключей тоже бывают затёрты ("realitySetting ", "secu"ity"), поэтому reality
    // определяем ещё и по паре publicKey + serverName
    const isReality = /"realitySettings"/.test(win) || /"security"\s*:\s*"reality"/.test(win) || (!!pbkM && !!snM);
    if (isReality && !pbkM) continue;
    const netM = win.match(/"network"\s*:\s*"(tcp|grpc|xhttp|ws)"/);
    const net = netM ? netM[1] : 'tcp';
    const sec = isReality ? 'reality' : (/"security"\s*:\s*"tls"/.test(win) ? 'tls' : 'none');
    const sidM = win.match(/"shortId"\s*:\s*"([0-9a-fA-F]{2,32})"/);
    const fpM = win.match(/"fingerprint"\s*:\s*"([a-z0-9]{3,20})"/);
    const stream = { network: net, security: sec };
    if (sec === 'reality') {
      stream.realitySettings = { show: false, fingerprint: fpM ? fpM[1] : 'chrome', serverName: snM ? snM[1] : addr, publicKey: pbkM[1] };
      if (sidM) stream.realitySettings.shortId = sidM[1];
    } else if (sec === 'tls') {
      stream.tlsSettings = { show: false, fingerprint: fpM ? fpM[1] : 'chrome', serverName: snM ? snM[1] : addr };
    }
    const key = `${proto}|${addr}|${port}|${net}|${sec}`;
    if (byKey.has(key)) { markSeen(key); continue; }
    const hm = addr.match(/edge-node([0-9a-z]+)/i);
    byKey.set(key, {
      key, proto, addr, port, net, sec, country: '',
      name: hm ? `Узел edge-node${hm[1]}` : `Узел ${addr}`,
      settings: { vnext: [{ address: addr, port, users: [{ id: idM[1], encryption: 'none', ...(win.match(/"flow"\s*:\s*"(xtls-rprx-vision|[^"]*)"/) && /xtls/.test(win) ? { flow: 'xtls-rprx-vision' } : {}) }] }] },
      stream,
      salvaged: true,
    });
    salvaged++;
    added++;
  }
}

console.log(`массивов outbounds: ${arrays} (распарсено ${arraysOk}) | одиночных объектов: ${singles} | спасено из затёртого JSON: ${salvaged} | отклонено (мусорный адрес): ${rejected}`);
console.log(`новых узлов в пул: ${added} | оживлено: ${revived} | было: ${before} | стало: ${byKey.size}`);

// --- запись пула ---
const backup = (f) => { if (fs.existsSync(f)) fs.copyFileSync(f, f + '.prev'); };
backup(POOL);
fs.writeFileSync(POOL, JSON.stringify({ updated: new Date().toISOString(), source: 'Happ.exe memory outbounds (accumulative)', nodes: [...byKey.values()] }, null, 1), 'utf8');

// --- сортировка: по стране (пустые в конце), затем адрес/порт/транспорт ---
// мёртвые (проверено geo-тестом: нет выхода) не занимают порты, но остаются в пуле
const deadCount = [...byKey.values()].filter(n => n.dead === true).length;
const nodes = [...byKey.values()].filter(n => n.dead !== true).sort((a, b) => {
  const ca = a.country || 'zzz', cb = b.country || 'zzz';
  if (ca !== cb) return ca.localeCompare(cb, 'ru');
  if (a.addr !== b.addr) return a.addr.localeCompare(b.addr);
  if (a.port !== b.port) return a.port - b.port;
  return `${a.net}${a.proto}`.localeCompare(`${b.net}${b.proto}`);
});

// --- companion ---
const inbounds = [], routing = [], index = [];
nodes.forEach((nd, i) => {
  const tag = `node-${i + 1}`;
  inbounds.push({
    tag: `in-${i + 1}`, listen: '127.0.0.1', port: PORT_BASE + i, protocol: 'socks',
    settings: { udp: true }, sniffing: { enabled: true, destOverride: ['http', 'tls'] },
  });
  routing.push({ type: 'field', inboundTag: [`in-${i + 1}`], outboundTag: tag });
  index.push({
    n: i + 1, tag, port: PORT_BASE + i, addr: nd.addr, port0: nd.port,
    proto: nd.proto, net: nd.net, sec: nd.sec, country: nd.country || '?', name: nd.name,
  });
});
routing.push({ type: 'field', network: 'tcp,udp', outboundTag: 'block' });
const cfg = {
  log: { loglevel: 'warning' },
  inbounds,
  outbounds: [
    ...nodes.map((nd, i) => ({ protocol: nd.proto, settings: nd.settings, streamSettings: nd.stream, tag: `node-${i + 1}` })),
    { protocol: 'blackhole', tag: 'block' },
  ],
  routing: { domainStrategy: 'AsIs', rules: routing },
};
backup(OUT_CFG); backup(OUT_IDX);
fs.writeFileSync(OUT_CFG, JSON.stringify(cfg, null, 1), 'utf8');
fs.writeFileSync(OUT_IDX, JSON.stringify({ generated: new Date().toISOString(), source: 'Happ.exe memory pool', nodes: index }, null, 1), 'utf8');

// --- синхронизация upstreams моста ---
let synced = 0, activeNote = '';
try {
  const bridge = JSON.parse(fs.readFileSync(BRIDGE_CFG, 'utf8').replace(/^\uFEFF/, ''));
  const up = bridge.upstreams || {};
  for (const k of Object.keys(up)) if (k.startsWith('happ-node-')) delete up[k];
  index.forEach((nd) => { up[`happ-node-${nd.n}`] = `socks5://127.0.0.1:${nd.port}`; synced++; });
  if (typeof bridge.active === 'string' && bridge.active.startsWith('happ-node-') && !up[bridge.active]) {
    bridge.active = 'happ-http';
    activeNote = ' (активный узел исчез -> вернул happ-http)';
  }
  bridge.upstreams = up;
  const tmp = BRIDGE_CFG + '.new';
  fs.writeFileSync(tmp, JSON.stringify(bridge, null, 4), 'utf8');
  // мост читает конфиг на лету, Windows может кратко держать файл - ретраим замену
  let lastErr = null;
  for (let attempt = 0; attempt < 10; attempt++) {
    try { fs.renameSync(tmp, BRIDGE_CFG); lastErr = null; break; }
    catch (e) { lastErr = e; Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 150); }
  }
  if (lastErr) throw lastErr;
} catch (e) {
  console.log('bridge.settings.json не синхронизирован:', e.message);
}

const byCountry = {};
for (const nd of index) byCountry[nd.country] = (byCountry[nd.country] || 0) + 1;
console.log('стран/узлов:', Object.entries(byCountry).map(([c, n]) => `${c}=${n}`).join(', ') + (deadCount ? ` (мёртвых в пуле, не поднято: ${deadCount})` : ''));
for (const nd of index) console.log(`  [${nd.n}] :${nd.port}  ${nd.country}  ${nd.proto}/${nd.net}/${nd.sec}  ${nd.addr}:${nd.port0}`);
console.log(`upstreams happ-node-* синхронизировано: ${synced}${activeNote}`);
console.log('файлы: companion-xray.json, nodes-index.json, nodes-pool.json (+ .prev бэкапы)');
