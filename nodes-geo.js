// nodes-geo.js - фактическая гео-проверка каждого узла через его socks-порт; правит country/name в nodes-index.json и nodes-pool.json
const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');

const PROJ = __dirname;
const IDX = path.join(PROJ, 'nodes-index.json');
const POOL = path.join(PROJ, 'nodes-pool.json');

function curl(args, timeout = 30000) {
  return new Promise((resolve) => {
    execFile('curl.exe', args, { encoding: 'utf8', timeout, windowsHide: true, maxBuffer: 1024 * 1024 },
      (err, stdout) => resolve(err ? '' : String(stdout).trim()));
  });
}

function egress(port) {
  return curl(['-x', `socks5h://127.0.0.1:${port}`, '-s', '-m', '25', 'https://api.ipify.org']);
}

async function geo(ip) {
  const raw = await curl(['--noproxy', '*', '-s', '-m', '15', `https://ipinfo.io/${ip}/json`]);
  try { const j = JSON.parse(raw); return { country: j.country || '', city: j.city || '', org: j.org || '' }; } catch { return null; }
}

const RU = { FI: 'Финляндия', LV: 'Латвия', CA: 'Канада', HK: 'Гонконг', DE: 'Германия', NL: 'Нидерланды', SE: 'Швеция', US: 'США', GB: 'Великобритания', FR: 'Франция', PL: 'Польша', EE: 'Эстония', LT: 'Литва', CH: 'Швейцария', AT: 'Австрия', IT: 'Италия', ES: 'Испания', TR: 'Турция', KZ: 'Казахстан', SG: 'Сингапур', JP: 'Япония', KR: 'Корея', IN: 'Индия', BR: 'Бразилия', AE: 'ОАЭ', MD: 'Молдова', RO: 'Румыния', CZ: 'Чехия', NO: 'Норвегия', DK: 'Дания', BE: 'Бельгия', IE: 'Ирландия', PT: 'Португалия', GR: 'Греция', BG: 'Болгария', HU: 'Венгрия', SK: 'Словакия', SI: 'Словения', HR: 'Хорватия', RS: 'Сербия', UA: 'Украина', AM: 'Армения', GE: 'Грузия', UZ: 'Узбекистан', KG: 'Киргизия', IS: 'Исландия', LU: 'Люксембург', MT: 'Мальта', CY: 'Кипр' };

async function main() {
  const idx = JSON.parse(fs.readFileSync(IDX, 'utf8').replace(/^\uFEFF/, ''));
  const results = new Array(idx.nodes.length);
  const geoCache = new Map();
  let next = 0;

  async function geoFor(ip) {
    if (!geoCache.has(ip)) geoCache.set(ip, geo(ip));
    return geoCache.get(ip);
  }

  async function worker() {
    while (true) {
      const i = next++;
      if (i >= idx.nodes.length) return;
      const n = idx.nodes[i];
      const ip = await egress(n.port);
      const g = ip ? await geoFor(ip) : null;
      const cc = g && g.country ? g.country : '';
      const countryRu = cc ? (RU[cc] || cc) : null;
      results[i] = { n: n.n, port: n.port, ip, cc, city: g ? g.city : '', org: g ? g.org : '', countryRu, prev: n.country };
      if (countryRu) n.country = countryRu;
      n.egressIp = ip || null;
      n.alive = !!ip;
      n.geo = g ? { cc, city: g.city, org: g.org } : null;
    }
  }

  const configured = Number(process.env.GEO_CONCURRENCY) || 4;
  const concurrency = Math.max(1, Math.min(configured, 8, idx.nodes.length || 1));
  await Promise.all(Array.from({ length: concurrency }, () => worker()));
  fs.writeFileSync(IDX, JSON.stringify(idx, null, 1), 'utf8');

  // обновляем пул по ключу (proto|addr|port|net|sec)
  if (fs.existsSync(POOL)) {
    try {
      const pool = JSON.parse(fs.readFileSync(POOL, 'utf8'));
      const byKey = new Map(pool.nodes.map(n2 => [n2.key, n2]));
      for (const n of idx.nodes) {
        const key = `${n.proto}|${n.addr}|${n.port0}|${n.net}|${n.sec}`;
        const p = byKey.get(key);
        if (p) { p.country = n.country; p.egressIp = n.egressIp; p.geo = n.geo; p.alive = n.alive; p.dead = !n.alive; }
      }
      fs.writeFileSync(POOL, JSON.stringify(pool, null, 1), 'utf8');
    } catch (e) { console.log('пул не обновлён:', e.message); }
  }

  console.log('=== фактический выход по узлам ===');
  for (const r of results) {
    if (!r) continue;
    const geoStr = r.cc ? `${r.cc}${r.city ? '/' + r.city : ''}` : '?';
    const flag = r.countryRu ? r.countryRu : '?';
    console.log(`  [${r.n}] :${r.port}  ip=${r.ip || '(нет ответа)'}  ${geoStr}  -> ${flag}${r.prev && r.prev !== flag ? ` (было: ${r.prev})` : ''}`);
  }
  const fail = results.filter(r => r && !r.ip).length;
  if (fail) console.log(`узлов без ответа: ${fail}`);
}

main().catch(e => {
  console.error('geo failed:', e.message);
  process.exit(1);
});
