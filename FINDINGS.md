# opencode-happ-bridge — REA findings (evidence record)

Target: OpenCode Desktop 2.0.32, `C:\Users\<user>\AppData\Local\Programs\@opencodedesktop\`

## Identity

| What | Value |
|---|---|
| Desktop app | OpenCode.exe, Electron layout (app.asar 176,943,854 bytes) |
| Bundled CLI | `resources\opencode-cli.exe` (Bun-compiled, `opencode-cli.version` = 2.0.32) |
| App userData | `C:\Users\<user>\AppData\Roaming\ai.opencode.desktop` |
| CLI config | `C:\Users\<user>\.config\opencode\` (opencode.jsonc, cli.json) |
| REA CLI evidence | `ev_fce72065877f335dc8a…3ade7e`, subject app.asar sha256 `2be5af3416f974209e992190dd480e260fecbf0319d3565ca87ce3731398f460`, provider `rea-javascript-application` v1, `integrity_policy=record-and-continue` |

## Routing of traffic inside OpenCode Desktop (from app.asar)

Internal bundle files (paths from asar header, parsed with the asar pickle header — files are exact-content copies at known byte offsets):

1. `out/main/index.js` — wrapper `runnerEntry`: sets userData, `app.setName`, and
   `app.commandLine.appendSwitch('proxy-bypass-list', '<-loopback>')`
   → Chromium is told that loopback IS allowed to be proxied (negated bypass). Combined with
   OpenCode's own browser-feature partition proxy, loopback traffic intentionally flows through
   `session.setProxy`. For the bridge this means: any `127.0.0.1` target that enters the bridge
   must be dialed **directly**, never re-wrapped into the upstream (done in `bridge.js`).
2. `out/main/desktop-CiR2Cmvk.js` — `DesktopInitialization` sequence:
   - `vm()` — rewrites `NO_PROXY`/`no_proxy` env to enforce `127.0.0.1`,`localhost`,`::1` entries.
   - `mi.setGlobalProxyFromEnv()` where `import mi from "node:http"` → calls the Node core API
     `http.setGlobalProxyFromEnv()` (Node ≥ 24.14.0 / 25.4.0, verified against nodejs docs:
     enables built-in proxy support for `fetch()` and `http(s).request()` from
     `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`; error is caught and logged as
     `failed to load proxy environment` — no such line appeared in the captured logs).
   - `DesktopCli.resolveBundled` — resolves the bundled CLI binary (`opencode-cli.exe`,
     staged copy under `userData\cli\<version>-<arch>\opencode-cli.exe`), builds `command: [binary]`.
3. Runtime evidence (`%APPDATA%\ai.opencode.desktop\logs\20261019T223348\main.log`):
   - `v2 CLI executable resolved { bundled: '...\opencode-cli.exe', packaged: true }`
   - `v2 CLI staged executable reused { path: '...\cli\2.0.32-x64\opencode-cli.exe' }`
   - `v2 CLI background service ready { url: 'http://127.0.0.1:45278', ... }`

Conversation chain confirmed live via Win32_Process parent chain:
`OpenCode.exe (13232) → opencode-cli.exe serve --service (7476) → powershell (this session)`.

## Existing proxy plumbing in the app (not the bridge's route)

`out/main/pane-bxT5y0e5.js` contains OpenCode's own browser-feature proxy:
`session.fromPartition(e.partition).setProxy({ mode:'fixed_servers', proxyRules: r.url, proxyBypassRules:'<-loopback>' })`
with basic-auth callback realm `'OpenCode Browser Proxy'` and `setWebRTCIPHandlingPolicy('disable_non_proxied_udp')`.
This runs in parallel with our approach and is left untouched.

## Happ (FlyFrog LLC) — what is listening

Live netstat + Win32_Process evidence (PIDs current at analysis time):

| Port | State | Process |
|---|---|---|
| `127.0.0.1:10808` | LISTENING | `xray.exe` (C:\Program Files\FlyFrogLLC\Happ\core\xray.exe, pid 4916) |
| `127.0.0.1:10809` | LISTENING | `xray.exe` (same) |
| `10.6.7.1:50106` | LISTENING | `happd.exe` (pid 2844 — Happ daemon, Tunnel/dnstt side) |
| `127.0.0.1:45278` | LISTENING | `opencode-cli.exe` (staged v2 CLI service) |

Extra observation: `happd.exe` opens outbound connections to `127.0.0.1:10808` — Happ's own daemon is chained through its bundled xray core. `$env:LOCALAPPDATA\Happ\routing.json` shows `routings: []` — routing rules are profile-subscription driven, NOT a local file we should edit.

## Verification performed

Functional, all against the live `_bridge` on `127.0.0.1:38409` (curl):

- CONNECT https via upstream `http://127.0.0.1:10809` (Happ xray) → 200, body received
- CONNECT https via upstream `socks5://127.0.0.1:10808` → 200, body received
- CONNECT https via `direct` → 200, body received
- absolute-form plain `http://example.com/` → 200
- `GET /__bridge/status` origin-form → 200 JSON
- hot-switch of `bridge.settings.json` `active` (name-based) → `config reloaded: active=… upstream=…` line in bridge.log, then next CONNECT follows the new upstream (log lines `CONNECT api.github.com:443 -> happ-socks`, `-> direct`, `-> happ-http`)

Live-run Notes (bugs found and fixed during verification):
1. PowerShell 5.1 `Set-Content -Encoding UTF8` writes a BOM; Node `JSON.parse` rejects it →
   `bridge.js` strips leading `\uFEFF`, and `switch.ps1` writes BOM-free UTF-8.
2. Non-atomic config rewrite → EBUSY mid-write → `switch.ps1` writes to `.new` + `Move-Item -Force`.
3. `switch.ps1` originally wrote the URL into `active` instead of the upstream key → fixed to always write the key name.

## Инцидент 2026-10-20 02:16: UnexpectedStatus: 502 в UI OpenCode

- Первый запуск OpenCode через лаунчер при активном мосте: все запросы рендерера к CLI-серверу
  (`http://127.0.0.1:45278`) возвращали 502, тост «Не удалось перенести данные».
- Причина (мой баг): в `handleAbsoluteForm` использовался `url.host` — это `hostname:port` целиком,
  после чего код ещё раз добавлял порт → цель `127.0.0.1:45278:45278` → `getaddrinfo ENOTFOUND`.
  bridge.log: `GET 127.0.0.1:45278:45278 ... request dial failed: getaddrinfo ENOTFOUND 127.0.0.1:45278`.
  CONNECT-запросы шли другим путём и работали — потому внешние API жили, падали только plain GET.
- Фикс: `const tHost = target.hostname` (без порта). Проверено absolute-form сырым сокетом:
  `GET http://127.0.0.1:45278/` через мост -> HTTP 200 (HTML CLI) вместо 502.
- Примечание: тот OpenCode-инстанс затем был перезапущен вручную без прокси (мост в цепочке не задействован).
  Для покрытия нужно перезапустить через лаунчер.

## Unknowns / limitations

- ~~"CLI traffic through the bridge"~~ RESOLVED: `bridge.log` живого запуска shows both routes — `CONNECT opencode.ai:443 -> happ-http` (CLI/undici) и `GET 127.0.0.1:45278 -> direct (loopback bypass)` (рендерер к CLI-серверу). Оба маршрута ходят через мост.
- `sessions.setProxy`-style per-session Chromium proxy for the renderer is set via the CLI switch `--proxy-server` (session-wide), not per-partition. The Electron `net` module traffic therefore shares the same route; the updater and the main process also go through it.
- REA integrity note: `node_modules/@lydell/node-pty-win32-x64/...OpenConsole.exe` declared sha256 (`7f68c840…`) contradicts on-disk bytes (`c2216ab9…`) — post-packaging signing/stripping of unpacked native binaries is common; bytes retained untrusted under `record-and-continue`, does not affect JS analysis paths used in this task.
- Element-scoped REA run included ALL 8307 tracked asar files; relationship expansion for renderer chunks was resource-truncated (`javascript_analysis_parent_result_budget_bytes` limits) — not material to this feature.

## Файлы созданы

```
C:\Builders\OpenCode\opencode-happ-bridge\
├── OpenCode-Happ.exe         единый лаунчер: меню + запуск OpenCode через мост + переключение узлов/апстримов
├── src\OpenCodeHapp.cs       исходник лаунчера (C#, .NET Framework)
├── build-exe.ps1             пересборка exe через csc.exe
├── Happ-Bridge.cmd           двойной клик — панель управления (menu.ps1)
├── menu.ps1                  интерактивная панель: запуск/перезапуск OpenCode, смена апстрима, статус, тест, стоп
├── bridge.js                 forward proxy: CONNECT + absolute-form, upstreams http/socks5/direct, hot config
├── bridge.settings.json      listen/host/port, active upstream, upstreams, bypass, timeouts
├── launch.opencode.ps1       starts bridge (if needed) + launches OpenCode with proxy env & --proxy-server
├── switch.ps1                hot-switches the active upstream (edits config; bridge reloads itself)
├── status.ps1                bridge/upstream/Happ/OpenCode process status
├── test-connection.ps1       4 curls through the bridge + loops
├── kill-opencode.ps1         gracefully closes OpenCode (CloseMainWindow -> force + orphan CLI); refuses inside-OpenCode
├── Kill-OpenCode.cmd         double-click wrapper for kill-opencode.ps1
├── check-proxy.ps1           is OpenCode currently connected through the bridge? (+ -Watch N delta mode)
├── happ-nodes.ps1            REAL Happ-subscription node switcher (companion-xray + hot swap + egress check)
├── Happ-Nodes.cmd            double-click interactive node menu
├── refresh-nodes.ps1         one-shot pool refresh: scan memory -> merge pool -> rebuild -> restart -> geo check
├── happ-scan.ps1             C# process-memory region scanner (-Probe / dump regions by needle)
├── nodes-pipeline.js         regions -> accumulative nodes-pool.json -> companion-xray.json + nodes-index.json + bridge upstream sync
├── nodes-geo.js              real egress check per node (socks port -> ipinfo) -> country in index/pool
├── companion-xray.json       companion xray config: one socks inbound (10901+) per node; contains sub credentials
├── nodes-pool.json           accumulative node pool (everything ever seen in Happ memory); contains sub credentials
├── nodes-index.json          node list (port/protocol/country) for happ-nodes.ps1
├── stop.ps1                  stops the bridge
└── FINDINGS.md               this file
```

## Переключатель узлов Happ — как добыт и чем доказан (2026-10-20 03:xx)

Задача: удобный переключатель прокси «из уже готовых подписок в Happ», настоящий, не заглушка.

Факты по пути:

1. **Домен подписки мёртв во внешнем DNS.** Лог Happ (`%LOCALAPPDATA%\Happ\logs\subscription_log.txt`)
   дал URL `https://sub.<provider>/<token>` (последняя успешная тяга 19.10 18:51, 134 862 B, «10 servers imported»;
   с 01:16 20.10 — «Failed to download»). DoH-проверка мимо Happ двумя независимыми рекурсорами
   (1.1.1.1 и dns.google) → `Status:3 NXDOMAIN` для A и AAAA; прямые/через socks/http-инбаунд тяги —.Connection refused/000.
   Вывод: вытащить список узлов из интернета нельзя — только из памяти работающего Happ.
2. **`subs.db` зашифрован.** SQLite, таблица `subscriptions`, `data` — `1,"<base64>"` (ензим версия+блоб), ключ неизвестен. Не взламывал.
3. **Скан памяти `Happ.exe` (Qt, ~760 MB readable) через VirtualQueryEx+ReadProcessMemory (C# Add-Type).**
   В памяти найдены готовые JSON-объекты подписки: серверные записи с `"remarks"` (имена серверов:
   🇫🇮 Финляндия (Hysteria2), 🇱🇻 Латвия) и полными outbound-структурами vless-reality
   (`fingerprint`, `publicKey`, `shortId`, `flow=xtls-rprx-vision`), а также hysteria2-варианты
   (протокол `hysteria` — xray их не умеет, отсечены фильтром). Объекты крупнее 512 KB → потребовалось
   окно чтения ±3 MB вокруг вхождения `remarks`; сбор сбалансированных JSON-подобъектов
   (`{"protocol":...}`) с привязкой к ближайшему `remarks` задней стороной раскладки
   (outbounds → remarks → routing).
4. **Компаньон-xray.** Собран `companion-xray.json`: по одному socks-входу `127.0.0.1:10901..10904`,
   на каждый entry правило `inboundTag → outboundTag` (strict mapping, без общий fallback), stray → `blackhole`.
   Ядро то же, что у Happ (`C:\Program Files\FlyFrogLLC\Happ\core\xray.exe`, 26.7.28 — поддерживает
   xhttp/grpc/reality). Рестарт по `-Action Ensure/Stop`.
5. **Egress-доказательство (не заглушка):** `curl -x socks5h://127.0.0.1:1090N https://api.ipify.org`:
   - 10901 (vless/reality/tcp node-<id>:443) → `<ip>` — FI Helsinki (AS<asn>)
   - 10902 (vless/reality/xhttp node-<id>:444) → `<ip>` — LV Riga (AS<asn>)
   - 10903 (vless/reality/tcp node-<id>:443) → LV
   - 10904 (vless/reality/grpc node-<id>:6437) → LV
   Прямой egress машины = `<ip>` — совпадает с Латвией, т.к. у Happ включён TUN-режим
   (`happd.exe` на `10.6.7.1:50106`); сравнение «direct vs узел» поэтому делается по РАЗНЫМ странам.
6. **Горячая смена через мост подтверждена вживую:** `happ-nodes.ps1 -Action Use 1` → мост
   `active=happ-node-1`, egress сменился 185.81… → <ip> (FI); `Use 2` → назад на LV.
   OpenCode не перезапускался, агент-сессия (живущая через мост) разрыва не заметила.
   После теста мост возвращён на `happ-http`.

Ограничение: найдены 2 из ~10 серверов подписки (Финляндия, Латвия; 4 usable vless-варианта).
Остальные хосты (node-<id>, <ip> FI, <ip> HK и пр.) присутствуют в памяти
фрагментарно и в usable-outbound-форму целиком не собираются (окна регионов режут). Расширение
списка = повторный скан после «проверки задержки» в Happ (прогрев всех узлов) или `-Extract`
пайплайн: `dump-memory.ps1 → extract-servers2.js → build-companion2.js → рестарт компаньона`.

### Уточнение 2026-10-20 (после перезагрузки машины): накопительный пул

Перезагрузка сменила pid'ы Happ (12080 → 7916) и обнулила Temp-дампы. Новый скан показал:
Happ держит в памяти конфиги **только недавно прогретых серверов** — в свежем процессе были
Канада (node-<id>) и Финляндия (node-<id>), Латвия (node-<id>) исчезла. Отсюда архитектурное
решение — **накопительный пул** (`nodes-pool.json`): каждый скан добавляет найденное, старое
не теряется; `nodes-pipeline.js` мержит пул, пересобирает `companion-xray.json`/`nodes-index.json`
и сам синхронизирует upstreams `happ-node-*` в `bridge.settings.json` (с бэкапом `.prev`).

Дополнительно: страна узла теперь определяется **фактическим egress** (`nodes-geo.js`: socks-порт →
`api.ipify.org` → `ipinfo.io`), а не только по `remarks`. Так «?» (node-<id>) стал Финляндией,
а Канада подтвердилась по IP `<ip>` (Beauharnois).

Проверено стрессом: 4 переключения подряд через мост (Канада `<ip>` ↔ Финляндия
`<ip>`), pid компаньона стабилен, в логе xray — `[in-N -> node-N]` на каждый запрос.

Практический вывод для пополнения списка: прогреть серверы в Happ («проверить задержку» всех
или по очереди переключить), затем `.\refresh-nodes.ps1` — один цикл: скан → пул → конфиг →
рестарт компаньона → гео-проверка → итоговый список.

### Второй проход 2026-10-20 (после прогрева узлов в Happ): общий конфиг подписки

После прогрева в памяти Happ обнаружился **общий конфиг подписки со всеми серверами** (tags
`proxy`, `proxy-3`…`proxy-11`: `<node-host>…`, `<ip>`, `<ip>`, `node-<id>`,
`node-<id>/70b` и др.). Но он лежит в переиспользованной куче и частично затёрт:
`"protoco,"`, `"secu"ity"`, `<node-host>`, `"port.rpr"`, вставки бинарного мусора.
`JSON.parse` такого текста падает.

Почему раньше находились только 2 узла: пайплайн искал объекты по шаблону `{"protocol"`, а в
этих конфигах `protocol` — не первый ключ. Исправлено: теперь разбираются массивы
`"outbounds": [...]`; `refresh-nodes.ps1` сканирует память по игле `"outbounds"`.

Добавлен salvage-проход (в `nodes-pipeline.js`): из битого JSON поля достаются по отдельности
(адрес, порт, UUID, publicKey, serverName, shortId), чинится типовое искажение домена
(`<provider-domain>.com` → `<provider-domain>`). Узел принимается только если UUID валиден, а для
reality — есть `publicKey`. Имена ключей тоже бывают затёрты, поэтому reality определяется ещё
и по паре `publicKey` + `serverName`.

Проверка фактом: каждый узел поднимается своим socks-входом и проверяется через `ipinfo`
(`nodes-geo.js`). Узлы без ответа помечаются `dead:true` в пуле и исключаются из
`companion-xray.json` — порт не занимают, нумерация не «прыгает» на мёртвых.

Итог — 4 живых узла в 4 странах, переключение каждого проверено через мост (без рестарта OpenCode):

| # | Страна | Выход IP | Транспорт |
|---|---|---|---|
| 1 | Канада | <ip> (Beauharnois) | vless/tcp/reality `node-<id>` |
| 2 | США | <ip> (New York) | vless/xhttp/reality `<node-host>` |
| 3 | Финляндия | <ip> (Helsinki) | vless/tcp/reality `node-<id>` |
| 4 | Франция | <ip> (Paris) | vless/tcp/reality `<node-host>` |

Что восстановить не удалось и почему:
- `<ip>` — затёрт `publicKey` (reality без него не поднимается);
- `node-<id>` — ключи из битого блока недостоверны, узел не отвечает (помечен мёртвым);
- `<node-host>…`, `<ip>:443/6437` — утрачены UUID/publicKey;
- `node-<id>`/`node-<id>:24443` — hysteria2 (xray такой протокол не умеет);
- `node-<id>`/`node-<id>` — в памяти только поля структур, JSON-конфига нет.

Вывод: для этих серверов нужна **целая копия конфига**. Практика: прогреть сервер в Happ и
сразу запустить `.\refresh-nodes.ps1` (накопительный пул сохранит всё, что успело прочитаться).

### Единый exe 2026-10-20: `OpenCode-Happ.exe`

Собран один лаунчер (C#, .NET Framework 4.x, `csc.exe`), внутри — меню и вся ежедневная логика:
запуск/перезапуск OpenCode через мост, список узлов по странам с реальным egress, горячее
переключение узлов и апстримов, статус, стоп моста. Сканер памяти Happ тоже перенесён в exe
(`[5]`): скан `"outbounds"` → `nodes-pipeline.js` → рестарт компаньона → `nodes-geo.js` →
отсев мёртвых → итоговый список. PowerShell в ежедневном цикле больше не участвует.

Две ошибки, найденные при проверке:
1. .NET `HttpWebRequest` переиспользовал keep-alive-туннель к мосту, и egress-проверка показывала
   IP **старого** узла (само переключение при этом работало). Лечится `req.KeepAlive = false`
   для проверочного запроса.
2. При рестарте компаньона exe держал открытым `companion-xray.out.log` и падал на повторном
   открытии. Лечится `FileShare.ReadWrite` + закрытием логов по `Exited` процесса.

Проверено: `--use 3`/`--use 1` меняют egress `<ip>` ↔ `<ip>`; `--refresh`
проходит полный цикл (4 узла, active сохраняется); меню `[3]` переключает узел и показывает
новый IP. Сборка: `.\build-exe.ps1` (исходник `src\OpenCodeHapp.cs`).

### Пост-апдейт OpenCode 2.1.1 (20.10.2026, вечер): прокси теряется при автообновлении

OpenCode Desktop обновился до **2.1.1** (актуальный stable: `/download/stable/windows-x64-nsis`
редиректит на `/files/bin/2.1.1/...`; CLI `2.1.1-x64`). После автообновления приложение
перезапустилось **без** `--proxy-server`, а фоновый сервер `opencode-cli serve --service`
(pid от прошлого запуска) пережил перезапуск и продолжил ходить напрямую к `opencode.ai`
(<ip>) — то есть мимо моста.

Лечение:
1. Лаунчер `[2]` теперь гасит и окно OpenCode, и фоновый `opencode-cli` (с ожиданием и повтором),
   чтобы новый сервер стартовал с окружением прокси; `[1]` при закрытом окне тоже убирает
   осиротевший сервер.
2. Прокси закреплён в конфиге сервера: `opencode-cli service set env HTTPS_PROXY
   http://127.0.0.1:38409` (+ `HTTP_PROXY`); `service get` подтверждает, конфиг переживает
   перезапуски и обновления.
3. Проверка фактом: после рестарта CLI (pid 4748) у него **нет прямых внешних соединений**,
   только `127.0.0.1:38409`; в `bridge.log` — `CONNECT models.opencode.ai:443 -> happ-node-2`
   и `CONNECT opencode.ai:443 -> happ-node-2`. Мост активен на `happ-node-2`
   (egress `<ip>`), Desktop запущен с `--proxy-server=http://127.0.0.1:38409`.

### Автопоиск порта моста (20.10.2026, ночь): почему OpenCode «умирал из-за мёртвого порта»

Симптом: OpenCode перестаёт ходить в сеть, потому что в его окружении/флаге закреплён порт моста
(`38409` или `10809`), а на этом порту давно никто не слушает. Причина — статический порт и
просроченный env.

Решение (только факты, проверено живьём):

1. `bridge.js` при `EADDRINUSE`/`EACCES` перебирает порты `preferred..preferred+100` и пишет
   фактический endpoint в `bridge.port.json` (`service/host/port/pid/configPath/startedAt`).
   Проверка: занят 38409 dummy-листенером → в `bridge.test.log` `port 127.0.0.1:38409 unavailable
   (EADDRINUSE), trying 38410`, `listening on 127.0.0.1:38410`, state `"port": 38410`.
2. `bridge-port.ps1` (`Find-BridgeEndpoint`/`Resolve-BridgePort`) — единый резолвер: state → TCP →
   скан слушающих портов диапазона с пробой `/__bridge/status` → fallback. Протухший state
   безопасен: после `Stop-Process` моста порт 38410 перестал отвечать и резолвер вернул
   `38409 running=False source=fallback`.
3. Все потребители переведены на резолвер: `status.ps1`, `switch.ps1`, `check-proxy.ps1`,
   `test-connection.ps1`, `happ-nodes.ps1`, `menu.ps1`, `launch.opencode.ps1`, а также
   `OpenCodeHapp.exe` (`ResolveBridgePort` в `src\OpenCodeHapp.cs`, пересобран).
   Проверка «порт уехал»: при занятом 38409 `status.ps1` показал
   `bridge: RUNNING on 127.0.0.1:38410 (port source: state, pid …)` +
   `preferred port 38409 was busy - real port is 38410`; `OpenCode-Happ.exe --status` и
   `happ-nodes.ps1 -Action Status` тоже увидели 38410 и egress через мост.
4. `launch.opencode.ps1` и C#-лаунчер синхронизируют env фонового сервера на живой порт
   (`opencode-cli service set env HTTPS_PROXY/HTTP_PROXY`, отключается `-NoServiceEnv` / не
   трогается при запущенном OpenCode).

Egress через мост после восстановления: `<ip>` (active `happ-node-2`), 4/4 пробы
`test-connection.ps1` PASS.



## Gemini desktop app: лендинг "страна не поддерживается" — это блок узла, а не региона

Разбор 2026-10-20 (приложение `%LOCALAPPDATA%\Google\Gemini`, профиль `%APPDATA%\Gemini`):

- Приложение Gemini (Electron, asar запакован) отказывается стартовать с сетевыми switch'ами
  (`--proxy-server`/PAC/host-rules) и remote debugging: в логе
  `refusing to start — a debugging or network-override switch is present`. Прокси берётся только
  из системной конфигурации Windows, поэтому единственный рычаг — `AutoConfigURL`.
- `file://` PAC Chromium не загружает (проверено: соединений через мост 0). HTTP-PAC работает: мост
  отдаёт `/proxy.pac`, в PAC — только домены из `pac.domains`, остальное `DIRECT`.
  Но HTTP-PAC зависит от живости моста: при рестарте/остановке моста Chromium не получает PAC и молча
  уходит в `DIRECT`, а Gemini кэширует лендинг «не поддерживается в вашей стране» уже с реального IP
  (проверено: PAC на мёртвый порт → приложение запускается, 14 прямых соединений). Поэтому в
  `AutoConfigURL` пишется inline `data:application/x-ns-proxy-autoconfig;base64,…` PAC: он всегда
  читается, Google-домены при мёртвом мосте падают (fail closed), остальной интернет идёт напрямую.
  Это и есть изоляция: `ProxyEnable=0`, глобального `ProxyServer` нет, машина сохраняет реальный IP.
  `/proxy.pac` оставлен для диагностики.
- `ip-api.com` через узел может отваливаться (socket hang up) — egress/страна проверяются через
  `https://ipinfo.io/json`.
- Настоящий признак блока: `GET https://gemini.google.com/app` через мост отдаёт
  `302 -> https://www.google.com/sorry/index?...` (IP узла помечен Google как abusive).
  При чистом IP — `200` и приложение отдаёт композер.
- `ok` HTTP не зависит от "страны" сам по себе: анонимный curl через заблокированный узел тоже
  отдаёт shell с `ql-editor` (решение о стране принимается клиентом). Поэтому проверка узла
  делается по коду/редиректу `/sorry`, а не по наличию композера в HTML.
- Лендинг «Gemini пока не поддерживается в вашей стране» рисуется и при RU-выходе, и при
  abuse-редиректе; страница кэшируется приложением и держится после смены узла. Лечение:
  холодный кэш (`Cache`, `Code Cache`, `GPUCache`, `Session Storage`, `shared_proto_db` …) +
  рестарт приложения. Автоматика: `argon-mcp\gemini-proxy.ps1 -Action on`.
- Побочный триггер: `switch.ps1` при hot-reload рвёт соединения, приложение уходит на `/` и
  кэширует лендинг. Поэтому в `switch.ps1` добавлен пропуск, если мост уже на этом апстриме.

Проверенные на 2026-10-20 узлы (egress через мост): 10901 US, 10902-10904 NL (<ip>,
Google-abuse), 10906/07 RU, 10909-10911 LV, 10912-10914 NL (<ip>), 10915 FI,
10918 IN, 10921 US, 10922 FI, 10923 FR, 10924 JP, 10925 NL (<ip>, Google-abuse);
10905/08/16/17/19/20 без egress.

## 2026-10-23: смена узла рвёт старые туннели (`/__bridge/reset`)

Проблема (обнаружена при разборе лимитов free-моделей): `attachTunnel` не ставит idle-timeout, а туннель
навсегда прибит к узлу, через который был установлен. После `switch.ps1`/`--use` keep-alive пул клиента
продолжает ходить через старый узел, т.е. со старым egress IP — для серверных лимитов по IP это тот же счётчик.

Реализация:
- `bridge.js`: реестр живых туннелей (`tunnels`), `closeTunnels()`, origin-form ручка `/__bridge/reset`
  (GET/POST, отвечает `{reset, active, upstream}`), поле `tunnels` в `/__bridge/status`;
- `switch.ps1`: после подтверждённой смены апстрима вызывает reset, флаг `-KeepTunnels` отключает;
- `OpenCodeHapp.cs`: `ResetTunnels()` после `SetActive` в `UseNode` и `SwitchByName`; exe пересобран.

Проверки (реально выполнены):
- `node bridge-reset-test.js` (временный мост на 38499, `direct`): до reset `tunnels=1`, ответ
  `{ reset: 1, active: 'direct', upstream: 'direct' }`, клиентский сокет закрыт, после reset `tunnels=0`,
  повторный CONNECT получает `HTTP/1.1 200 Connection Established` → PASS;
- временный мост на 38498 + `switch.ps1 -Target happ-http`: `tunnels closed: 1`, после смены `tunnels=0`;
- `csc` собрал `OpenCode-Happ.exe` (38400 байт), `--status`/`--upstreams` работают.

Не проверено: разрыв туннелей на живом OpenCode под нагрузкой (требует перезапуска моста на новый код).
