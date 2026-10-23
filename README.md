# OpenCode ⇄ Happ Bridge

**Горячее переключение прокси для OpenCode Desktop на Windows — без перезапуска приложения.**

[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D4?logo=windows&logoColor=white)](#требования)
[![Node.js](https://img.shields.io/badge/node-%E2%89%A524.14-339933?logo=nodedotjs&logoColor=white)](#требования)
[![PowerShell](https://img.shields.io/badge/powershell-5.1%2B-5391FE?logo=powershell&logoColor=white)](#требования)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![English](https://img.shields.io/badge/docs-English-lightgrey.svg)](README.en.md)

Локальный forward-прокси, который стоит между OpenCode (Desktop и CLI) и апстримом.
Апстрим — Happ (Xray), конкретный узел подписки, SOCKS5 или `direct` — меняется на лету,
пока OpenCode работает. Трафик всех остальных приложений не затрагивается.

```text
┌──────────────┐   --proxy-server /   ┌────────────────┐   http CONNECT │ socks5 │ direct   ┌──────────────┐
│ OpenCode     │   HTTPS_PROXY env    │  happ-bridge   │ ─────────────────────────────────► │ upstream     │
│ Desktop/CLI  │ ───────────────────► │ 127.0.0.1:38x  │                                    │ Happ / node  │
└──────────────┘                      └────────────────┘ ◄──── смена апстрима на лету ───── └──────────────┘
```

## Зачем это нужно

- **OpenCode читает прокси только при старте.** `--proxy-server` и переменные окружения
  применяются к процессу в момент запуска; сменить выходной узел «на ходу» штатно нельзя.
- **Лимиты free-моделей считаются по внешнему IP.** Новый узел — новый счётчик, но уже
  открытые CONNECT-туннели остаются на старом узле. Мост умеет их рвать по команде.
- **Системный прокси не нужен.** Ни `WinINET`, ни глобальные переменные окружения: проксируется
  только OpenCode, остальной интернет идёт напрямую.

## Возможности

| Возможность | Как это выглядит |
|---|---|
| Горячая смена апстрима | `.\switch.ps1 -Target happ-socks` — новые соединения уходят в новый апстрим, OpenCode не перезапускается |
| Разрыв «залипших» туннелей | `switch.ps1` / `--use` закрывают открытые CONNECT-туннели, чтобы внешний IP действительно сменился |
| Переключение узлов Happ | список узлов со странами и **реальным egress IP**, выбор одной командой |
| Автопоиск порта | предпочтительный `38409`; если занят — берётся следующий свободный, фактический endpoint пишется в `bridge.port.json` |
| PAC-изоляция | `/proxy.pac` и inline `data:` PAC для приложений, которые не принимают `--proxy-server` (Gemini), только для перечисленных доменов |
| Единый exe | `OpenCode-Happ.exe` — меню, запуск, переключение узлов, статус. Без PowerShell в ежедневной работе |
| Диагностика | `/__bridge/status` (соединения, байты, живые туннели), `status.ps1`, `check-proxy.ps1`, `test-connection.ps1` |
| Loopback всегда напрямую | запросы внутрь `127.0.0.1` не уходят в апстрим (иначе внутренний CLI-сервер OpenCode получает 502) |

Подробный разбор бинарника и живые проверки — в [FINDINGS.md](FINDINGS.md).

## Требования

| Компонент | Версия / примечание |
|---|---|
| Windows | 10 / 11 |
| PowerShell | 5.1+ (встроенный) |
| Node.js | ≥ 24.14 (проверено на v24.21.0) — нужен мосту и пайплайну узлов |
| OpenCode Desktop | установлен в `%LOCALAPPDATA%\Programs\@opencodedesktop\` |
| Happ + подписка | опционально: только для апстримов `happ-http`, `happ-socks`, `happ-node-*` |
| .NET Framework 4.x | опционально: только для пересборки `OpenCode-Happ.exe` (`csc.exe` уже в Windows) |

## Установка

```powershell
git clone https://github.com/disemay12/opencode-happ-bridge.git
cd opencode-happ-bridge

# локальный конфиг (в git не попадает — можно свободно править)
Copy-Item bridge.settings.example.json bridge.settings.json

# проверить, что мост поднимается и апстримы живы (OpenCode не нужен)
.\test-connection.ps1
```

Дальше — запуск OpenCode через мост:

```powershell
.\launch.opencode.ps1          # мост стартует сам, если ещё не запущен
# или двойной клик по Happ-Bridge.cmd — текстовая панель управления
.\menu.ps1
```

Если OpenCode уже открыт, новый экземпляр лишь сфокусирует окно, а прокси-окружение не применится —
нужен честный перезапуск:

```powershell
.\launch.opencode.ps1 -Restart
```

> ⚠️ Не запускай `-Restart` из агент-сессии, которая сама живёт внутри OpenCode Desktop: это убьёт
> текущий ход. Закрой OpenCode руками и запусти скрипт из обычной консоли.

### Сборка единого exe (опционально)

```powershell
.\build-exe.ps1        # соберёт OpenCode-Happ.exe из src\OpenCodeHapp.cs
.\OpenCode-Happ.exe    # меню
```

## Быстрый старт

```powershell
.\OpenCode-Happ.exe --launch      # запустить OpenCode через мост
.\OpenCode-Happ.exe --list        # узлы + текущий выходной IP
.\OpenCode-Happ.exe --use 3       # переключить мост на узел 3
.\OpenCode-Happ.exe --status      # мост / узлы / OpenCode / egress
.\OpenCode-Happ.exe --refresh     # обновить пул узлов из памяти Happ
.\OpenCode-Happ.exe --help
```

Те же действия скриптами:

```powershell
.\switch.ps1 -Target happ-http                    # HTTP 127.0.0.1:10809 (апстрим Happ по умолчанию)
.\switch.ps1 -Target happ-socks                   # SOCKS5 127.0.0.1:10808
.\switch.ps1 -Target direct                       # напрямую, минуя Happ
.\switch.ps1 -Target "socks5://127.0.0.1:10808"   # произвольный апстрим
.\switch.ps1 -Target happ-http -KeepTunnels       # не рвать открытые туннели

.\status.ps1                  # сводка: мост, апстрим, счётчики, процессы
.\check-proxy.ps1 -Watch 15   # реально ли OpenCode ходит через мост (флаг + netstat + дельта трафика)
.\stop.ps1                    # остановить мост
```

## Узлы Happ (опционально)

Мост умеет держать собственный инстанс xray — по одному SOCKS-входу на каждый узел подписки
(`10901+`, конфиг `companion-xray.json`) — и переключаться между ними без перезапуска OpenCode.

```powershell
.\happ-nodes.ps1                        # список узлов + текущий egress IP
.\happ-nodes.ps1 -Action Use -Name 3    # переключить на узел 3 (страна показывается после проверки)
.\happ-nodes.ps1 -Action Ensure         # поднять компаньон-xray
.\happ-nodes.ps1 -Action Stop           # остановить компаньон-xray

.\refresh-nodes.ps1                     # пересобрать пул узлов из памяти Happ
```

Happ держит в памяти конфиги только тех серверов, что недавно использовались или прогревались.
Чтобы собрать больше стран — прогони в Happ «проверить задержку» всех серверов (или переключи их
по очереди) и снова запусти `.\refresh-nodes.ps1`: пул накопительный, ничего не теряется между
запусками. Каждый поднятый узел проверяется фактическим выходом; мёртвые помечаются и не занимают порт.

## Изоляция: прокси только там, где нужно

| Потребитель | Как заворачивается | Область действия |
|---|---|---|
| OpenCode Desktop / CLI | `--proxy-server=http://127.0.0.1:<порт>` + `HTTPS_PROXY` / `ALL_PROXY` в env процесса (+ `opencode-cli service set env`) | только процессы OpenCode |
| Gemini | inline `data:application/x-ns-proxy-autoconfig;base64,…` PAC в `AutoConfigURL`, `ProxyEnable=0` | только домены из `pac.domains` |
| Всё остальное | ничего | настоящий IP, напрямую |

Мост никогда не должен становиться системным прокси: если `ProxyEnable=1` указывает на
`127.0.0.1:<порт>`, его остановка отрежет от сети **все** WinINET-приложения. При остановке моста
`stop.ps1` снимает глобальный прокси и чистит env фонового сервера OpenCode.

## Если что-то не работает

| Симптом | Причина / решение |
|---|---|
| `bridge.port.json` указывает на мёртвый порт | безвредно: TCP-проверка отбраковывает запись, порт ищется заново (state → scan → fallback) |
| Внешний IP не меняется после смены узла | живы старые CONNECT-туннели; `switch.ps1` / `--use` рвут их, `-KeepTunnels` оставляет |
| OpenCode после автообновления ходит напрямую | перезапускай только через `[2]` / `--restart`: лаунчер гасит и окно, и фоновый `opencode-cli serve --service` |
| В логе нет `CONNECT models.opencode.ai:443 -> happ-node-N` | мост не в цепочке: `.\check-proxy.ps1` покажет, пришёл ли `--proxy-server` к процессу |
| `happ-node-*` не поднимаются | проверь путь к `xray.exe` в `happ-nodes.ps1` (по умолчанию `C:\Program Files\FlyFrogLLC\Happ\core\xray.exe`) |

## Структура репозитория

| Файл | Что делает |
|---|---|
| `OpenCode-Happ.exe` (собирается) / `src\OpenCodeHapp.cs` | единый лаунчер: меню, запуск, узлы, апстримы, статус |
| `build-exe.ps1` | пересборка exe через `csc.exe` (.NET Framework 4.x) |
| `bridge.js` | forward-прокси (std-lib Node): CONNECT + absolute-form, апстримы `http`/`socks5`/`direct`, `/proxy.pac`, `/__bridge/status`, `/__bridge/reset` |
| `bridge.settings.example.json` | шаблон конфигурации: порт, апстримы, PAC-домены, таймауты |
| `bridge-port.ps1` | резолвер живого порта моста (`bridge.port.json` → TCP → скан → fallback) |
| `launch.opencode.ps1` | запуск OpenCode с прокси-окружением + синхронизация env фонового сервера |
| `switch.ps1`, `status.ps1`, `stop.ps1` | смена апстрима, сводка состояния, остановка |
| `check-proxy.ps1`, `test-connection.ps1` | проверка цепочки «сейчас» и полный тест моста |
| `menu.ps1`, `Happ-Bridge.cmd` | текстовая панель управления |
| `happ-nodes.ps1`, `Happ-Nodes.cmd` | компаньон-xray и переключение узлов подписки |
| `happ-scan.ps1`, `nodes-pipeline.js`, `nodes-geo.js`, `refresh-nodes.ps1` | скан памяти Happ → пул узлов → конфиг компаньона → проверка egress |
| `kill-opencode.ps1`, `Kill-OpenCode.cmd` | аккуратное закрытие OpenCode (окно → force → сироты CLI) |
| `FINDINGS.md` | доказательная запись реверс-разбора и проверок |

## Безопасность

- `bridge.settings.json`, `bridge.port.json`, логи и `*.prev` — локальное состояние, в git не попадают.
- `companion-xray.json` и `nodes-pool.json` содержат **credentials подписки** (UUID, `publicKey`).
  Они в `.gitignore` — не публикуй и не коммить их.
- Мост слушает только `127.0.0.1` и не принимает входящих соединений из сети.

## Лицензия

[MIT](LICENSE).
