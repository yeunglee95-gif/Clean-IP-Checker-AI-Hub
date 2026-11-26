# AI Hub — the checked front door

One window for everything Claude- and ChatGPT-shaped, which refuses to open anything
unless the tunnel is genuinely doing its job.

Double-click **AI Hub** on the desktop (or search "AI Hub" in the Start menu).

## What happens when you open it

```
double-click
   │
   ├─ window paints immediately ("Checking …")
   ├─ 14 checks run (~8 s)
   │
   ├─ every fatal check passes → tiles appear, click one
   └─ a fatal check failed    → "Not safe to launch", tiles hidden
```

| Check | Fatal? | What it proves |
|---|---|---|
| TUN adapter | yes | the `Meta Tunnel` card is up |
| Default route | yes | `0.0.0.0/0` runs through that card, not the Wi-Fi card |
| Core process | yes | `verge-mihomo` is alive to enforce the rules |
| Exit IP | yes | the measured exit is one you approved |
| WebRTC / STUN | yes | a UDP lookup sees the same address, so WebRTC leaks nothing |
| IP reputation | yes | the exit is not flagged as a proxy, VPN or datacenter (the cleanip.io question) |
| Anthropic exits | yes | `claude.ai`, `api.anthropic.com` and `console.anthropic.com` all see the same exit |
| Country | no | the exit says `US` |
| Locale | no | `en-US` |
| Timezone | no | `Pacific Standard Time` |
| Exit stability | no | the tunnel's exit has not jumped around in 48 h; samples taken while the tunnel was off are reported separately, because those are a leak, not instability |
| IPv6 | no | no v6 address is escaping around a v4 tunnel |
| DNS | no | names are answered inside the tunnel, not by the ISP |
| Fingerprint | no | no Chinese font families and no DNT/GPC flag (the fuck-claude.app question) |

Non-fatal failures show amber, so you see them without being locked out.

## The buttons

| Button | What it does |
|---|---|
| **ADD** | adds a tile — web page, program, Store app or terminal command. Writes straight into `apps.json`, so it survives a restart. |
| **EXITS** | opens the approved-exit list: add or remove the addresses the gate will accept |
| **RE-CHECK** | runs all 14 checks again without closing the window |
| **✕** / Esc | closes |

### Adding a tile

Press **ADD**, pick one of the four kinds, and the Target field tells you exactly what it wants:

| Kind | Target takes | Example | Lands in |
|---|---|---|---|
| Web page | a full address; `https://` is added for you | `example.org` | Web consoles |
| Program | full path to an .exe | `C:\Program Files\App\App.exe` | Desktop apps |
| Store app | a Store AppID — run `Get-StartApps \| Where Name -eq "App"` to find it | `Claude_pzs8sxrjxfjjc!Claude` | Desktop apps |
| Terminal | the command to run | `claude` or `codex` | Terminals |

The Group field pre-fills from the kind but you can type any section name — a new group
appears in the order its first tile was added. Name and Target are required; everything else
is optional. The tile is written to `apps.json` immediately, so it is there next launch, and a
tile whose brand mark the hub does not know simply shows no icon rather than breaking.

### Removing a tile

Hover a tile and press the small **×** that appears at its right edge. The tile disappears and
its entry in `apps.json` is kept with `"enabled": false`, so a misclick costs nothing: adding
the same target again brings the same tile back with its name, note and group, instead of
creating a duplicate.

## The Lisa box's public face

The VPS answers scanners with a real site, not a placeholder, and the hub carries a

| Where | What it is |
|---|---|
| `https://209.87.93.95:8443/` | the whole site served directly, self-signed, the scanner surface |

Pages: home, notes index plus three written articles, work, about, contact, privacy, and a
the sourcing box, so both servers read as two properties of one company. No web fonts, no
analytics, no third-party requests: loading a page tells nobody that it loaded.

nginx server blocks serve them (8443 direct, and the `127.0.0.1:8444` fallback behind REALITY).


The gate only launches when the measured exit IP is on the approved list. That list is
**`exits.json`**, editable in the hub under **EXITS**: type an IPv4 address and a label, press
ADD, then **RE-CHECK** to measure against the new list. REMOVE takes an address out. The file
is the source of truth; `Check-Tunnel.ps1` falls back to its built-in pair only if the file is
missing or unreadable, so a broken file can never lock the machine out of launching.

Keep the list tight. Every address on it is somewhere traffic can leave from without the gate
noticing a change — one entry per profile you actually use is the point.

The hub **stays open after a launch**, so you can open two apps in a row without
coming back to the desktop. Apps it launches are separate processes and keep running
even after you close the hub.

## One hub, one icon

Only ever one hub runs. A second click on any shortcut finds the open window, sends it a
"show yourself" signal, and exits — no duplicate process, no second set of checks. If the
window is minimised, that signal restores it.

**Clicking the taskbar button toggles it.** First click brings the hub up, the next click
minimises it, the one after restores it. The window has no frame, so the shell has no
minimise box to act on; the window answers `SC_MINIMIZE` and `SC_RESTORE` itself, off the
message, because doing the work inside the window procedure deadlocks the shell.

When it gets that signal the hub raises itself: restore, bring to top, hold *always on top* for
about a second, then `SwitchToThisWindow`. That last step matters: Windows often refuses to
move keyboard focus to a background process, but a topmost window is still drawn above
whatever is in front, so the click is always answered visibly. The taskbar button is there as
the guaranteed fallback — it carries the AI Hub icon and is named "AI Hub", not "Windows
PowerShell".

Two rules keep a click from ever disappearing:

- **The checks run off the UI thread.** All 14 checks do network and DNS work for about
  eight seconds. On the UI thread that froze the window: no repaint, no click, no raise —
  the window sat blank and looked dead. They now run in a runspace; the window paints in
  about a second with a "Checking" pill and stays responsive throughout.
- **The knock is latched from start-up.** The raise event exists before any check runs, so a
  second click during start-up is remembered and answered on the first tick, not lost
  because the hub had not yet created its end of the event.

A bug worth remembering: `FindWindow($null, 'AI Hub')` silently searches for the class
`""` instead of "any class", so the launcher never found the window and a second click did
nothing at all. `[NullString]::Value` is what passes a real NULL.

## When it looks dead, read `gate-log.txt`

Every start-up stage is stamped, so "nothing happened" can be told apart from "it started
and failed":

| Line | Means |
|---|---|
| `START process` | the script began |
| `WINDOW shown` | the window painted |
| `CHECK started (background)` | the checks were launched |
| `GATE pass=...` | the checks finished and what they found |
| `RAISE requested` / `RAISE forwarded` | a second click was received |
| `CHECK failed to start:` / `UI error:` | a failure with its message |

No `START process` line does not, by itself, prove anything: the launcher cannot write that log
either, so a missing line only tells you the script never started. `START process` followed by
no `WINDOW shown` means the script died before painting — a parse or path error in
`Check-Tunnel.ps1` is the usual cause, and the line carries the process id so it can be matched
against the process list. A successful start looks like `START process` → `WINDOW shown` →
`CHECK started` → `GATE`.

## Starting it with no console window

Both shortcuts (desktop and Start menu) point at **`AIHub.exe`**. It is a
GUI-subsystem program, compiled from `Launcher.cs`:

```
csc /target:winexe /optimize+ /out:AIHub.exe Launcher.cs
```

It starts `powershell.exe` with `UseShellExecute = false` and
`CreateNoWindow = true` (`CREATE_NO_WINDOW`), so **no console window is ever
created**. There is therefore nothing to see, nothing to close, and nothing
whose close can take the hub down with it.

Why the earlier `Launch-AIHub.vbs` was not enough: `WScript.Shell.Run` and
`PowerShell -WindowStyle Hidden` both only *hide* a console that Windows has
already made. A hidden console is still a console — it can be shown again, it
shows up in the window list, and closing it ends every process attached to it,
including the hub. Measured with a 4 ms window tracer, the VBS left a real
`ConsoleWindowClass` window in existence (hidden); `AIHub.exe` leaves none.

`Start-AIHub.ps1` also hides any console it happens to inherit, as insurance in
case an older shortcut or a stray `powershell.exe` starts it. `Launch-AIHub.vbs`
is now a stub that just runs `AIHub.exe`, so stale shortcuts still work.

## Adding anything

Either press **ADD**, or edit `apps.json` by hand:

```json
{
  "name": "Gemini",
  "note": "Web chat",
  "glyph": "◇",
  "kind": "url",
  "target": "https://gemini.google.com",
  "group": "Web consoles",
  "enabled": true
}
```

| Field | Meaning |
|---|---|
| `name` | what the tile says |
| `note` | the small grey line under it |
| `glyph` | one character used as the icon |
| `icon` | `"claude"` — uses the real Claude app icon from `assets/claude.png` |
| `mark` | `"openai"` — draws the OpenAI mark as a vector |
| `kind` | `url`, `exe`, `appid` or `cli` |
| `target` | the URL, exe path, Store AppID, or command |
| `cwd` | `cli` only — the folder the terminal opens in |
| `group` | section heading, in the order groups first appear |
| `enabled` | `false` hides a tile without deleting it |

`kind` differences:

- **`url`** — opens in your default browser.
- **`exe`** — runs a program by path.
- **`appid`** — a Microsoft Store app (`Get-StartApps | Where Name -eq 'Claude'`).
- **`cli`** — opens Windows Terminal, `cd`s to `cwd`, runs the command.

## The override

If a fatal check fails, a muted "Launch anyway (logged, not recommended)" link appears.
Using it writes the reason to `gate-log.txt`. It exists so a wrong rule never locks you
out of your own machine — not as a normal path.

## Files

| File | What it is |
|---|---|
| `Start-AIHub.ps1` | the window, the tiles, the buttons |
| `AIHub.exe` | the shortcuts' target: GUI subsystem, starts PowerShell with no console |
| `Launcher.cs` | its 40-line source, so it can be rebuilt rather than trusted |
| `Launch-AIHub.vbs` | stub that runs `AIHub.exe`, for older shortcuts |
| `Check-Tunnel.ps1` | the 14 checks and the approved-exit list |
| `apps.json` | the tiles |
| `assets/claude.png` | the real Claude icon, taken from the installed app |
| `ai-hub.ico` | the shortcut icon |
| `gate-log.txt` | every launch, every refusal, every override, every ADD |
| `history.json` | exit IPs for the 48 h stability check |

**To approve another exit**, add its IP to `$script:AllowedExits` at the top of
`Check-Tunnel.ps1`.

## Why a window and not a web page

A browser page cannot start a program on this machine without a small web server running
alongside it. A native window has no server, no installer, no background process and no
admin rights: delete the folder and it is gone.

## Known limits

- It checks *before* launch. If the tunnel dies while Claude is already open, the app
  stays open — a firewall kill switch is the only thing that covers that.
- **IP reputation is asked of `ip-api.com`, not of cleanip.io.** cleanip's own check is
  behind an antibot challenge (`/api/v2/challenge`) and needs a button press in the page,
  so scraping it produces either a false green or a false red. The gate measures the two
  questions cleanip answers — *is this exit a proxy/VPN/datacenter?* and *do all Anthropic
  hosts see the same exit?* — directly, and says so.
- **The fingerprint check is a proxy, not the browser.** It reads installed CJK font
  families from GDI, which is what `fuck-claude.app` weights at 17. It does not reproduce
  that tool's canvas/WebGL/emoji measurements. 27 Chinese families on this machine is the
  reason that tile is amber; removing them is a system change, so it warns instead of
  blocking.
- The `cli` tiles inherit whatever `codex`/`claude` resolve to on `PATH`.
