# OpenCode ⇄ Happ Bridge

**Hot-swappable proxy for OpenCode Desktop on Windows — switch the exit node without restarting the app.**

[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D4?logo=windows&logoColor=white)](#requirements)
[![Node.js](https://img.shields.io/badge/node-%E2%89%A524.14-339933?logo=nodedotjs&logoColor=white)](#requirements)
[![PowerShell](https://img.shields.io/badge/powershell-5.1%2B-5391FE?logo=powershell&logoColor=white)](#requirements)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Русский](https://img.shields.io/badge/docs-Русский-lightgrey.svg)](README.md)

A local forward proxy that sits between OpenCode (Desktop and CLI) and its upstream. The upstream —
Happ/Xray, a specific subscription node, SOCKS5, or `direct` — can be changed while OpenCode keeps
running. Nothing else on the machine is affected.

```text
┌──────────────┐   --proxy-server /   ┌────────────────┐   http CONNECT │ socks5 │ direct   ┌──────────────┐
│ OpenCode     │   HTTPS_PROXY env    │  happ-bridge   │ ─────────────────────────────────► │ upstream     │
│ Desktop/CLI  │ ───────────────────► │ 127.0.0.1:38x  │                                    │ Happ / node  │
└──────────────┘                      └────────────────┘ ◄──── upstream swapped live ────── └──────────────┘
```

## Why

- **OpenCode reads proxy settings only at launch.** `--proxy-server` and environment variables are
  bound to the process at startup, so the exit node cannot normally change mid-session.
- **Free-model quotas are counted per external IP.** A new node is a new counter, but live CONNECT
  tunnels stay pinned to the old node — the bridge can cut them on demand.
- **No system-wide proxy.** Only OpenCode is proxied; the rest of the machine keeps its real IP.

## Features

| Feature | How it looks |
|---|---|
| Live upstream switch | `.\switch.ps1 -Target happ-socks` — new connections use the new upstream, no restart |
| Stale tunnel reset | `switch.ps1` / `--use` close open CONNECT tunnels so the egress IP really changes |
| Happ node switcher | node list with countries and **real egress IP**, one command to switch |
| Port auto-discovery | preferred `38409`; if busy, the next free port is used and published in `bridge.port.json` |
| PAC isolation | `/proxy.pac` and inline `data:` PAC for apps that reject `--proxy-server` (Gemini), limited to listed domains |
| Single exe | `OpenCode-Happ.exe` — menu, launch, node switching, status. No PowerShell in daily use |
| Diagnostics | `/__bridge/status` (connections, bytes, live tunnels), `status.ps1`, `check-proxy.ps1`, `test-connection.ps1` |
| Loopback stays direct | requests to `127.0.0.1` never enter the upstream (otherwise OpenCode's internal CLI server returns 502) |

Binary analysis and live verification log: [FINDINGS.md](FINDINGS.md) (Russian).

## Requirements

| Component | Version / note |
|---|---|
| Windows | 10 / 11 |
| PowerShell | 5.1+ (built in) |
| Node.js | ≥ 24.14 (verified on v24.21.0) — used by the bridge and the node pipeline |
| OpenCode Desktop | installed under `%LOCALAPPDATA%\Programs\@opencodedesktop\` |
| Happ + subscription | optional, only for `happ-http`, `happ-socks`, `happ-node-*` upstreams |
| .NET Framework 4.x | optional, only to rebuild `OpenCode-Happ.exe` (`csc.exe` ships with Windows) |

## Installation

```powershell
git clone https://github.com/disemay12/opencode-happ-bridge.git
cd opencode-happ-bridge

# local config (git-ignored, edit freely)
Copy-Item bridge.settings.example.json bridge.settings.json

# verify bridge + upstreams (OpenCode not required)
.\test-connection.ps1
```

Start OpenCode through the bridge:

```powershell
.\launch.opencode.ps1          # starts the bridge if needed
# or double-click Happ-Bridge.cmd for the text control panel
.\menu.ps1
```

If OpenCode is already running, a new instance only focuses the window — proxy env is applied only on
a real restart:

```powershell
.\launch.opencode.ps1 -Restart
```

> ⚠️ Do not run `-Restart` from an agent session that itself lives inside OpenCode Desktop — it kills
> the running turn. Close OpenCode manually and run the script from a normal console.

### Build the single exe (optional)

```powershell
.\build-exe.ps1        # builds OpenCode-Happ.exe from src\OpenCodeHapp.cs
.\OpenCode-Happ.exe    # menu
```

## Quick start

```powershell
.\OpenCode-Happ.exe --launch      # launch OpenCode through the bridge
.\OpenCode-Happ.exe --list        # nodes + current egress IP
.\OpenCode-Happ.exe --use 3       # switch the bridge to node 3
.\OpenCode-Happ.exe --status      # bridge / nodes / OpenCode / egress
.\OpenCode-Happ.exe --refresh     # refresh the node pool from Happ memory
.\OpenCode-Happ.exe --help
```

Same with scripts:

```powershell
.\switch.ps1 -Target happ-http                    # HTTP 127.0.0.1:10809 (Happ default upstream)
.\switch.ps1 -Target happ-socks                   # SOCKS5 127.0.0.1:10808
.\switch.ps1 -Target direct                       # bypass Happ
.\switch.ps1 -Target "socks5://127.0.0.1:10808"   # arbitrary upstream
.\switch.ps1 -Target happ-http -KeepTunnels       # keep open tunnels alive

.\status.ps1                  # bridge / upstream / counters / processes
.\check-proxy.ps1 -Watch 15   # is OpenCode really going through the bridge (flag + netstat + traffic delta)
.\stop.ps1                    # stop the bridge
```

## Happ nodes (optional)

The bridge can run its own xray instance — one SOCKS inbound per subscription node (`10901+`, config
`companion-xray.json`) — and switch between them without restarting OpenCode.

```powershell
.\happ-nodes.ps1                        # node list + current egress IP
.\happ-nodes.ps1 -Action Use -Name 3    # switch to node 3
.\happ-nodes.ps1 -Action Ensure         # start companion xray
.\happ-nodes.ps1 -Action Stop           # stop companion xray

.\refresh-nodes.ps1                     # rebuild the node pool from Happ memory
```

Happ keeps in memory only the servers recently used or probed. To collect more countries, run
"check latency" for all servers in Happ (or switch through them) and run `.\refresh-nodes.ps1` again:
the pool is cumulative and nothing is lost between runs. Every node is verified by its real egress; dead
ones are marked and release their port.

## Isolation: proxy only where it is needed

| Consumer | How it is wrapped | Scope |
|---|---|---|
| OpenCode Desktop / CLI | `--proxy-server=http://127.0.0.1:<port>` + `HTTPS_PROXY` / `ALL_PROXY` in the process env (+ `opencode-cli service set env`) | OpenCode processes only |
| Gemini | inline `data:application/x-ns-proxy-autoconfig;base64,…` PAC in `AutoConfigURL`, `ProxyEnable=0` | only domains from `pac.domains` |
| Everything else | nothing | real IP, direct |

The bridge must never become the system proxy: with `ProxyEnable=1` pointing at `127.0.0.1:<port>`,
stopping it would cut every WinINET app off the network. On stop, `stop.ps1` clears the global proxy and
the background OpenCode service env.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `bridge.port.json` points at a dead port | harmless: TCP probe rejects it and the port is re-discovered (state → scan → fallback) |
| Egress IP does not change after switching node | old CONNECT tunnels are alive; `switch.ps1` / `--use` cut them, `-KeepTunnels` keeps them |
| OpenCode goes direct after a self-update | restart only via `[2]` / `--restart`: the launcher kills both the window and `opencode-cli serve --service` |
| No `CONNECT models.opencode.ai:443 -> happ-node-N` in the log | the bridge is not in the chain: `.\check-proxy.ps1` shows whether the flag reached the process |
| `happ-node-*` does not start | check the `xray.exe` path in `happ-nodes.ps1` (default `C:\Program Files\FlyFrogLLC\Happ\core\xray.exe`) |

## Repository layout

| File | Purpose |
|---|---|
| `OpenCode-Happ.exe` (built) / `src\OpenCodeHapp.cs` | single launcher: menu, launch, nodes, upstreams, status |
| `build-exe.ps1` | rebuild the exe with `csc.exe` (.NET Framework 4.x) |
| `bridge.js` | forward proxy (std-lib Node): CONNECT + absolute-form, `http`/`socks5`/`direct` upstreams, `/proxy.pac`, `/__bridge/status`, `/__bridge/reset` |
| `bridge.settings.example.json` | config template: port, upstreams, PAC domains, timeouts |
| `bridge-port.ps1` | live port resolver (`bridge.port.json` → TCP → scan → fallback) |
| `launch.opencode.ps1` | launches OpenCode with proxy env and syncs the background service env |
| `switch.ps1`, `status.ps1`, `stop.ps1` | switch upstream, report state, stop |
| `check-proxy.ps1`, `test-connection.ps1` | "right now" chain check and full bridge test |
| `menu.ps1`, `Happ-Bridge.cmd` | text control panel |
| `happ-nodes.ps1`, `Happ-Nodes.cmd` | companion xray and subscription node switching |
| `happ-scan.ps1`, `nodes-pipeline.js`, `nodes-geo.js`, `refresh-nodes.ps1` | Happ memory scan → node pool → companion config → egress check |
| `kill-opencode.ps1`, `Kill-OpenCode.cmd` | graceful OpenCode shutdown (window → force → orphan CLI) |
| `FINDINGS.md` | evidence log of the binary analysis and live checks |

## Security

- `bridge.settings.json`, `bridge.port.json`, logs and `*.prev` are local state and git-ignored.
- `companion-xray.json` and `nodes-pool.json` contain **subscription credentials** (UUID, `publicKey`).
  They are git-ignored — never publish or commit them.
- The bridge binds to `127.0.0.1` only and accepts no inbound connections from the network.

## License

[MIT](LICENSE).
