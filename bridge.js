'use strict';
// opencode-happ-bridge / bridge.js
// Local HTTP forward proxy that gives OpenCode a stable address while the real
// upstream (Happ xray HTTP/SOCKS, direct, or any custom URL) can be swapped at
// runtime by editing bridge.settings.json.
//
// transport: client --(HTTP absolute-form / CONNECT)--> bridge --(direct | http CONNECT | socks5)--> target
//
// loopback destinations are always forwarded directly (OpenCode appends
// `<-loopback>` to Chromium's proxy-bypass-list, so 127.0.0.1 traffic DOES enter
// the bridge and must not be re-routed into the upstream).

const http = require('node:http');
const https = require('node:https');
const tls = require('node:tls');
const net = require('node:net');
const fs = require('node:fs');
const path = require('node:path');
const { URL } = require('node:url');

const DEFAULT_CONFIG = path.join(__dirname, 'bridge.settings.json');
const configPath = process.argv[2] ? path.resolve(process.argv[2]) : DEFAULT_CONFIG;

// Actual listening endpoint is published here so every consumer (PS scripts,
// OpenCode-Happ.exe, the CLI service env) can find the bridge even when the
// preferred port was occupied and the bridge moved to the next free one.
const STATE_PATH = path.join(path.dirname(configPath), 'bridge.port.json');
const PORT_SCAN_LIMIT = 100;

// PAC served by the bridge itself (/proxy.pac): WinINET apps that cannot take
// command-line proxy switches (the Gemini desktop app refuses --proxy-server)
// get the bridge ONLY for the listed domains. Everything else stays DIRECT, so
// the machine keeps its real IP and a dead bridge cannot black-hole the network.
const DEFAULT_PAC_DOMAINS = [
  'google.com', 'googleapis.com', 'gstatic.com', 'googleusercontent.com',
  'ggpht.com', 'gvt1.com', 'gvt2.com', 'youtube.com', 'ytimg.com', 'withgoogle.com',
];

const startedAt = Date.now();
const stats = {
  connections: 0,
  active: 0,
  errors: 0,
  bytesUp: 0,   // client -> bridge -> upstream
  bytesDown: 0, // upstream -> bridge -> client
};

// Live CONNECT tunnels. A tunnel keeps the upstream node it was dialed through
// for its whole lifetime, so switching the upstream only affects new dials -
// /__bridge/reset exists to cut the stale ones (e.g. when the egress IP is what
// the remote side rates-limits).
const tunnels = new Set();

function closeTunnels() {
  const all = Array.from(tunnels);
  for (const t of all) { try { t.destroy(); } catch { } }
  return all.length;
}

// ---------------------------------------------------------------- config ---

let config;
config = loadConfig();

function loadConfig() {
  const raw = fs.readFileSync(configPath, 'utf8').replace(/^\uFEFF/, ''); // tolerate editors writing a BOM
  const cfg = JSON.parse(raw);
  if (!cfg.listen || !cfg.upstreams) throw new Error('bridge settings missing listen/upstreams');
  if (!cfg.active || !(cfg.active in cfg.upstreams)) {
    throw new Error(`active upstream "${cfg.active}" is not defined in upstreams`);
  }
  config = normalize(cfg);
  return config;
}

function normalize(cfg) {
  const out = { ...cfg };
  out.bypass = new Set([
    '127.0.0.1', 'localhost', '[::1]', '::1', '.localhost',
    ...((cfg.bypass || []).map(s => String(s).toLowerCase())),
  ]);
  if (!out.idleTimeoutMs) out.idleTimeoutMs = 120000;
  if (!out.connectTimeoutMs) out.connectTimeoutMs = 12000;
  if (out.verbose === undefined) out.verbose = true;
  const pacDomains = cfg.pac && Array.isArray(cfg.pac.domains) && cfg.pac.domains.length
    ? cfg.pac.domains
    : DEFAULT_PAC_DOMAINS;
  out.pac = {
    domains: pacDomains
      .map(d => String(d).trim().toLowerCase().replace(/^\./, ''))
      .filter(Boolean),
  };
  out.parsed = {};
  for (const [name, value] of Object.entries(cfg.upstreams || {})) {
    out.parsed[name] = parseUpstream(value);
  }
  return out;
}

function parseUpstream(value) {
  if (value === 'direct' || value === 'DIRECT') return { kind: 'direct' };
  let u;
  try { u = new URL(value); } catch { return { kind: 'invalid', value }; }
  if (u.protocol === 'http:') {
    return { kind: 'http', host: u.hostname, port: Number(u.port || 80) };
  }
  if (u.protocol === 'socks5:' || u.protocol === 'socks:') {
    return { kind: 'socks5', host: u.hostname, port: Number(u.port || 1080) };
  }
  return { kind: 'invalid', value };
}

const CONFIG_NAME = path.basename(configPath);
let reloadTimer = null;
fs.watch(path.dirname(configPath), { persistent: false }, (event, filename) => {
  // The bridge writes its own stdout into this directory; without the name
  // filter every log line would trigger a config reload.
  if (filename && String(filename) !== CONFIG_NAME) return;
  clearTimeout(reloadTimer);
  reloadTimer = setTimeout(() => {
    try {
      const before = config.active;
      loadConfig();
      if (config.active !== before) {
        log(`config reloaded: active=${config.active} upstream=${describe(config.parsed[config.active])}`);
      }
    } catch (err) {
      log(`config reload failed, keeping previous: ${err.message}`);
    }
  }, 150);
});

// ------------------------------------------------------------- utilities ---

function log(msg) {
  if (config && config.verbose === false) return;
  process.stdout.write(`[bridge ${new Date().toISOString()}] ${msg}\n`);
}

function describe(u) {
  if (!u) return 'unknown';
  if (u.kind === 'direct') return 'direct';
  if (u.kind === 'http') return `http://${u.host}:${u.port}`;
  if (u.kind === 'socks5') return `socks5://${u.host}:${u.port}`;
  return String(u.value || 'invalid');
}

function hostFromAuthority(authority) {
  // "127.0.0.1:38409" / "[::1]:443" / "example.com" -> host without port
  const bracket = authority.match(/^\[([^\]]+)\](?::\d+)?$/);
  if (bracket) return bracket[1];
  const plain = authority.match(/^([^:]+)(?::\d+)?$/);
  return plain ? plain[1] : authority;
}

function isLoopbackHost(host) {
  const h = hostFromAuthority(String(host || '')).toLowerCase();
  return h === '127.0.0.1' || h === '::1' || h === 'localhost' || h.endsWith('.localhost');
}

function isBypassed(host) {
  if (isLoopbackHost(host)) return true;
  const h = hostFromAuthority(String(host || '')).toLowerCase();
  for (const rule of config.bypass) {
    if (rule === h) return true;
    if (rule.startsWith('.') && h.endsWith(rule)) return true;
    if (rule.startsWith('*.') && h.endsWith(rule.slice(1))) return true;
  }
  return false;
}

function targetFromAuthority(authority) {
  // host:port, handles IPv6 [::1]:443
  const m = authority.match(/^(\[[^\]]+\]|[^:]+)(?::(\d+))?$/);
  if (!m) return null;
  return { host: m[1], port: Number(m[2] || 443) };
}

const HOP_HEADERS = new Set([
  'connection', 'proxy-connection', 'keep-alive', 'proxy-authenticate',
  'proxy-authorization', 'te', 'trailer', 'transfer-encoding', 'upgrade',
]);

function cleanHeaders(headers) {
  const out = {};
  for (const [name, value] of Object.entries(headers || {})) {
    if (HOP_HEADERS.has(name.toLowerCase())) continue;
    if (name.toLowerCase().startsWith('proxy-')) continue;
    out[name] = value;
  }
  return out;
}

function armIdleTiming(socket, ms) {
  socket.setTimeout(ms, () => socket.destroy());
}

class OneShotSocketAgent extends http.Agent {
  constructor(socket) {
    super({ keepAlive: false });
    this.tunnel = socket;
  }
  createConnection(options, callback) {
    callback(null, this.tunnel);
  }
}

class OneShotTlsSocketAgent extends https.Agent {
  constructor(socket, servername) {
    super({ keepAlive: false });
    this.tunnel = socket;
    this.servername = servername;
  }
  createConnection(options, callback) {
    callback(null, tls.connect({ socket: this.tunnel, servername: this.servername }));
  }
}

// ------------------------------------------------------- upstream dialing ---

function dialRaw(target, upstream, cb) {
  const host = String(target.host).replace(/^\[|\]$/g, '');
  const port = target.port;
  let settled = false;
  const finish = (err, socket) => {
    if (settled) return;
    settled = true;
    if (socket) {
      socket.setNoDelay(true);
      armIdleTiming(socket, config.idleTimeoutMs);
    }
    cb(err, socket);
  };

  if (upstream.kind === 'direct') {
    const s = net.connect(port, host);
    s.setTimeout(config.connectTimeoutMs, () =>
      s.destroy(new Error(`direct connect timeout ${host}:${port}`)));
    s.once('error', err => finish(err));
    s.once('connect', () => finish(null, s));
    return;
  }

  if (upstream.kind === 'http') {
    let req;
    try {
      req = http.request({
        host: upstream.host,
        port: upstream.port,
        method: 'CONNECT',
        path: `${target.host}:${target.port}`,
        headers: { host: `${target.host}:${target.port}` },
        setHost: false,
        agent: false,
      });
    } catch (err) {
      return finish(err);
    }
    req.setTimeout(config.connectTimeoutMs, () => {
      req.destroy(new Error(`upstream(${describe(upstream)}) CONNECT timeout`));
    });
    req.once('error', err => finish(new Error(`upstream(${describe(upstream)}): ${err.message}`)));
    req.once('connect', (res, socket, head) => {
      if (res.statusCode !== 200) {
        socket.destroy();
        return finish(new Error(`upstream(${describe(upstream)}) CONNECT refused: HTTP ${res.statusCode}`));
      }
      if (head && head.length) socket.write(head);
      finish(null, socket);
    });
    req.end();
    return;
  }

  if (upstream.kind === 'socks5') {
    return socks5Connect(upstream, host, port, (err, socket) => finish(err, socket));
  }

  return finish(new Error(`unsupported upstream "${describe(upstream)}"`));
}

// minimal SOCKS5 client (NO_AUTH only)
function socks5Connect(upstream, host, port, cb) {
  const socket = net.connect(upstream.port, upstream.host);
  let stage = 0;
  let buf = Buffer.alloc(0);
  let settled = false;

  const done = (err, res) => {
    if (settled) return;
    settled = true;
    cb(err, res);
  };

  socket.setTimeout(config.connectTimeoutMs, () => {
    socket.destroy(new Error(`upstream(${describe(upstream)}) connect timeout`));
  });

  socket.once('error', err => done(new Error(`upstream(${describe(upstream)}): ${err.message}`)));

  socket.once('connect', () => {
    socket.write(Buffer.from([0x05, 0x01, 0x00])); // VER=5, 1 method, NO_AUTH
    stage = 1;
  });

  socket.on('data', chunk => {
    buf = Buffer.concat([buf, chunk]);
    if (stage === 1) {
      if (buf.length < 2) return;
      if (buf[0] !== 0x05 || buf[1] !== 0x00) {
        socket.destroy();
        return done(new Error(`upstream(${describe(upstream)}) SOCKS5 handshake rejected (code 0x${buf[1].toString(16)})`));
      }
      const hostLen = Buffer.byteLength(host);
      const greeting = Buffer.alloc(7 + hostLen);
      greeting[0] = 0x05; greeting[1] = 0x01; greeting[2] = 0x00; greeting[3] = 0x03;
      greeting[4] = hostLen;
      greeting.write(host, 5, 'utf8');
      greeting.writeUInt16BE(port, 5 + hostLen);
      socket.write(greeting);
      stage = 2;
      buf = buf.subarray(2);
      return;
    }
    if (stage === 2) {
      // reply layout: VER(1) REP(1) RSV(1) ATYP(1) ADDR(varies) PORT(2)
      if (buf.length < 4) return;
      const atyp = buf[3];
      const addrLen = atyp === 0x01 ? 4 : atyp === 0x04 ? 16 : atyp === 0x03 ? (1 + (buf[4] || 0)) : -1;
      if (addrLen < 0 || buf.length < 4 + addrLen + 2 || (atyp === 0x03 && buf.length < 5)) {
        if (addrLen < 0) {
          socket.destroy();
          return done(new Error(`upstream(${describe(upstream)}) SOCKS5 reply: bad ATYP 0x${atyp.toString(16)}`));
        }
        return;
      }
      if (buf[1] !== 0x00) {
        socket.destroy();
        return done(new Error(`upstream(${describe(upstream)}) SOCKS5 target refused: REP=${buf[1]}`));
      }
      socket.setTimeout(0);
      socket.pause();
      socket.removeAllListeners('data');
      // The proxy may pipeline target data right after the SOCKS5 reply;
      // unshift it so the caller's pipe sees every byte.
      const rest = buf.subarray(4 + addrLen + 2);
      if (rest.length) socket.unshift(rest);
      done(null, socket);
    }
  });
}

// ------------------------------------------------------------- plumbing ---

function countBytes(socket, field) {
  socket.on('data', chunk => { stats[field] += chunk.length; });
}

function attachTunnel(clientSocket, head, serverSocket, release) {
  let torn = false;
  const tunnel = { destroy: () => teardown() };
  const teardown = () => {
    if (torn) return;
    torn = true;
    tunnels.delete(tunnel);
    clientSocket.destroy();
    serverSocket.destroy();
    release();
  };
  tunnels.add(tunnel);
  // Install handlers before writing: the client may already have disconnected
  // while the upstream was dialing.
  clientSocket.once('close', teardown);
  clientSocket.once('error', teardown);
  serverSocket.once('close', teardown);
  serverSocket.once('error', teardown);
  if (clientSocket.destroyed || serverSocket.destroyed) {
    teardown();
    return;
  }
  try {
    clientSocket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    if (head && head.length) serverSocket.write(head);
  } catch {
    teardown();
    return;
  }
  countBytes(clientSocket, 'bytesUp');   // client -> tunnel
  countBytes(serverSocket, 'bytesDown'); // tunnel -> client
  clientSocket.pipe(serverSocket);
  serverSocket.pipe(clientSocket);
}

// ------------------------------------------------------------- handlers ---

function buildPac(port, domains) {
  const rules = domains
    .map(d => `(host === ${JSON.stringify(d)} || dnsDomainIs(host, ${JSON.stringify('.' + d)}))`)
    .join(' || ');
  if (!rules) {
    return [
      '// generated by opencode-happ-bridge: pac.domains is empty, everything goes direct',
      'function FindProxyForURL(url, host) { return "DIRECT"; }',
      '',
    ].join('\n');
  }
  return [
    '// generated by opencode-happ-bridge: listed domains through the bridge, everything else direct',
    'function FindProxyForURL(url, host) {',
    '  host = host.toLowerCase();',
    `  if (${rules}) return "PROXY 127.0.0.1:${port}";`,
    '  return "DIRECT";',
    '}',
    '',
  ].join('\n');
}

function handleOriginForm(req, res) {
  if (req.url === '/proxy.pac' || req.url === '/__bridge/pac') {
    const address = server.address();
    if (!address) {
      res.writeHead(503, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('bridge is not listening yet\n');
      return;
    }
    const body = buildPac(address.port, config.pac.domains);
    res.writeHead(200, {
      'Content-Type': 'application/x-ns-proxy-autoconfig; charset=utf-8',
      'Cache-Control': 'no-store, no-cache, must-revalidate',
      'Content-Length': Buffer.byteLength(body),
    });
    res.end(body);
    log(`PAC served (${config.pac.domains.length} domains, -> 127.0.0.1:${address.port})`);
    return;
  }
  if (req.url === '/__bridge/status') {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(statusPayload(), null, 2));
    return;
  }
  if (req.url === '/__bridge/reset') {
    const closed = closeTunnels();
    const upstream = describe(config.parsed[config.active]);
    log(`reset: closed ${closed} tunnel(s); active=${config.active} upstream=${upstream}`);
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ reset: closed, active: config.active, upstream }, null, 2));
    return;
  }
  res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end('opencode-happ-bridge: origin-form requests accept only /__bridge/status, /__bridge/reset and /proxy.pac\n');
}

function handleAbsoluteForm(req, res) {
  let target;
  try { target = new URL(req.url); } catch {
    res.writeHead(400);
    res.end('bridge: bad absolute-form URL');
    return;
  }
  const tHost = target.hostname; // NB: url.host уже содержит порт (127.0.0.1:45278) — для dial/SNI/логов нужно имя без порта
  const tPort = Number(target.port) || (target.protocol === 'https:' ? 443 : 80);
  const bypass = isBypassed(tHost);
  const upName = bypass ? 'direct (loopback bypass)' : config.active;
  const up = bypass ? { kind: 'direct' } : config.parsed[config.active];
  if (!up || up.kind === 'invalid') {
    res.writeHead(502, { 'Content-Type': 'text/plain' });
    res.end(`bridge: upstream "${upName}" is invalid; fix bridge.settings.json`);
    return;
  }
  stats.connections += 1;
  stats.active += 1;
  let closed = false;
  let upstreamReq = null;
  let agent = null;
  let upstreamSocket = null;
  const rel = () => {
    if (closed) return;
    closed = true;
    stats.active = Math.max(0, stats.active - 1);
    if (upstreamReq) { try { upstreamReq.destroy(); } catch { } }
    if (agent) { try { agent.destroy(); } catch { } }
    if (upstreamSocket) { try { upstreamSocket.destroy(); } catch { } }
  };
  // Attach before dialing: the client can disappear while the upstream is
  // being established, and the close event would otherwise be lost.
  res.once('close', rel);

  log(`${req.method} ${tHost}:${tPort} -> ${upName}`);

  dialRaw({ host: tHost, port: tPort }, up, (err, socket) => {
    if (closed) {
      if (socket) { try { socket.destroy(); } catch { } }
      return;
    }
    if (err) {
      stats.errors += 1;
      rel();
      log(`request dial failed: ${err.message}`);
      if (!res.destroyed) {
        try {
          res.writeHead(502, { 'Content-Type': 'text/plain' });
          res.end(`bridge dial failed: ${err.message}`);
        } catch { }
      }
      return;
    }
    upstreamSocket = socket;
    if (res.destroyed) { rel(); return; }
    const isHttpsTarget = target.protocol === 'https:';
    const AgentClass = isHttpsTarget ? OneShotTlsSocketAgent : OneShotSocketAgent;
    agent = new AgentClass(socket, tHost);
    const headers = cleanHeaders(req.headers);
    headers.host = req.headers.host || target.host; // include non-default port
    const makeReq = isHttpsTarget ? https.request : http.request;

    upstreamReq = makeReq(target, {
      method: req.method,
      path: target.pathname + (target.search || ''),
      headers,
      agent,
    });

    req.pipe(upstreamReq);
    countBytes(req, 'bytesUp'); // client -> bridge

    upstreamReq.once('response', upstreamRes => {
      if (closed) { try { upstreamRes.destroy(); } catch { } return; }
      countBytes(upstreamRes, 'bytesDown');
      res.writeHead(upstreamRes.statusCode, upstreamRes.headers);
      upstreamRes.pipe(res);
      upstreamRes.once('end', () => { try { agent.destroy(); } catch { } });
    });
    upstreamReq.once('error', err => {
      stats.errors += 1;
      log(`request upstream error: ${err.message}`);
      rel();
      try { res.destroy(); } catch { }
    });
  });
}

function handleConnect(req, clientSocket, head) {
  const target = targetFromAuthority(req.url || '');
  if (!target) {
    clientSocket.destroy();
    return;
  }
  const bypass = isBypassed(target.host);
  const upName = bypass ? 'direct (loopback bypass)' : config.active;
  const up = bypass ? { kind: 'direct' } : config.parsed[config.active];
  if (!up || up.kind === 'invalid') {
    clientSocket.end('HTTP/1.1 502 Bad Gateway\r\n\r\nbridge: active upstream is invalid\n');
    return;
  }
  stats.connections += 1;
  stats.active += 1;
  let released = false;
  const release = () => {
    if (released) return;
    released = true;
    stats.active = Math.max(0, stats.active - 1);
  };
  let clientGone = false;
  const onClientGone = () => {
    clientGone = true;
    release();
  };
  clientSocket.once('close', onClientGone);
  clientSocket.once('error', onClientGone);
  log(`CONNECT ${target.host}:${target.port} -> ${upName}`);

  dialRaw(target, up, (err, socket) => {
    if (err) {
      stats.errors += 1;
      release();
      log(`CONNECT ${target.host}:${target.port} failed: ${err.message}`);
      try { clientSocket.end('HTTP/1.1 502 Bad Gateway\r\n\r\n'); } catch { }
      try { clientSocket.destroy(); } catch { }
      return;
    }
    if (clientGone || clientSocket.destroyed) {
      try { socket.destroy(); } catch { }
      release();
      return;
    }
    // attachTunnel installs its own close/error handlers and owns the release.
    clientSocket.removeListener('close', onClientGone);
    clientSocket.removeListener('error', onClientGone);
    attachTunnel(clientSocket, head, socket, release);
  });
}

function statusPayload() {
  const address = server.address();
  return {
    service: 'opencode-happ-bridge',
    pid: process.pid,
    host: address && address.address,
    port: address && address.port,
    configPath,
    uptimeMs: Date.now() - startedAt,
    active: config.active,
    upstream: describe(config.parsed[config.active]),
    tunnels: tunnels.size,
    upstreams: Object.fromEntries(Object.entries(config.parsed).map(([k, v]) => [k, describe(v)])),
    pac: {
      url: address && address.port ? `http://127.0.0.1:${address.port}/proxy.pac` : null,
      domains: config.pac.domains,
    },
    stats,
  };
}

// ---------------------------------------------------------------- listen ---

const server = http.createServer((req, res) => {
  const isAbsoluteForm = /^[a-z][a-z0-9+.-]*:\/\//i.test(req.url);
  if (!isAbsoluteForm) {
    if (isLoopbackHost(req.headers.host || 'localhost')) {
      return handleOriginForm(req, res);
    }
    res.writeHead(400, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('opencode-happ-bridge: this is a forward proxy; use absolute-form URLs or CONNECT\n');
    return;
  }
  handleAbsoluteForm(req, res);
});
server.on('connect', handleConnect);
server.on('clientError', (err, socket) => {
  stats.errors += 1;
  if (socket.writable) socket.end('HTTP/1.1 400 Bad Request\r\n\r\n');
});
function writePortState(port) {
  const payload = {
    service: 'opencode-happ-bridge',
    host: config.listen.host,
    port,
    pid: process.pid,
    configPath,
    startedAt: new Date(startedAt).toISOString(),
  };
  const tmp = `${STATE_PATH}.${process.pid}.tmp`;
  try {
    fs.writeFileSync(tmp, JSON.stringify(payload, null, 2) + '\n', 'utf8');
    fs.renameSync(tmp, STATE_PATH);
  } catch (err) {
    log(`cannot write ${STATE_PATH}: ${err.message}`);
  }
}

function clearPortState() {
  try {
    const state = JSON.parse(fs.readFileSync(STATE_PATH, 'utf8'));
    if (state && state.pid === process.pid) fs.unlinkSync(STATE_PATH);
  } catch { /* missing or foreign state - leave it alone */ }
}

function listenOnce(port) {
  return new Promise((resolve, reject) => {
    const cleanup = () => {
      server.removeListener('error', onError);
      server.removeListener('listening', onListening);
    };
    const onError = err => { cleanup(); reject(err); };
    const onListening = () => { cleanup(); resolve(server.address().port); };
    server.once('error', onError);
    server.once('listening', onListening);
    try {
      server.listen(port, config.listen.host);
    } catch (err) {
      cleanup();
      reject(err);
    }
  });
}

async function listenWithDiscovery() {
  const preferred = Number(config.listen.port);
  const base = Number.isInteger(preferred) && preferred > 0 && preferred < 65536 ? preferred : 38409;
  const last = Math.min(65535, base + PORT_SCAN_LIMIT);
  let lastError = null;
  for (let port = base; port <= last; port++) {
    try {
      return await listenOnce(port);
    } catch (err) {
      lastError = err;
      if (err.code === 'EADDRINUSE' || err.code === 'EACCES') {
        log(`port ${config.listen.host}:${port} unavailable (${err.code}), trying ${port + 1}`);
        continue;
      }
      throw err;
    }
  }
  throw lastError || new Error(`no free port in ${base}..${last}`);
}

let shuttingDown = false;
function shutdown(code) {
  if (shuttingDown) return;
  shuttingDown = true;
  clearPortState();
  try { server.close(() => process.exit(code)); } catch { process.exit(code); }
  setTimeout(() => process.exit(code), 1500).unref();
}

process.on('exit', clearPortState);
process.on('SIGINT', () => shutdown(0));
process.on('SIGTERM', () => shutdown(0));

listenWithDiscovery().then(port => {
  server.on('error', err => log(`server error: ${err.message}`));
  writePortState(port);
  log(`listening on ${config.listen.host}:${port}`);
  log(`active=${config.active} upstream=${describe(config.parsed[config.active])}`);
  log(`config: ${configPath}`);
  log(`port state: ${STATE_PATH}`);
}).catch(err => {
  log(`FATAL: cannot bind ${config.listen.host}:${config.listen.port} (+${PORT_SCAN_LIMIT}): ${err.message}`);
  process.exit(3);
});
