# AI Hub

A small Windows front door for the AI tools you actually use. It checks that your
tunnel is up and exiting from an address you approved, and only then lets you launch
Claude, ChatGPT, Codex or any app, terminal command or web page you add yourself.

It is one window, no installer, no background service, no admin rights. Delete the
folder and it is gone.

![AI Hub: a check panel above three rows of app tiles](docs/screenshot.png)

## What it checks before letting you launch

| Check | Fatal? | What it proves |
|---|---|---|
| TUN adapter | yes | the tunnel adapter is up |
| Default route | yes | every packet is intercepted, not just some |
| Core process | yes | the proxy core is alive to enforce the rules |
| Exit IP | yes | the measured exit is one you approved |
| WebRTC / STUN | yes | a UDP lookup sees the same address, so WebRTC leaks nothing |
| IP reputation | yes | the exit is not flagged as a proxy, VPN or datacenter |
| Anthropic exits | yes | claude.ai, api.anthropic.com and console.anthropic.com all see the same exit |
| Country | no | the exit is in the country you expect |
| Locale | no | the Windows locale you want the apps to see |
| Timezone | no | the machine's timezone matches the exit |
| Exit stability | no | the tunnel's exit has not jumped around in 48 h |
| IPv6 | no | no v6 address is escaping around a v4 tunnel |
| DNS | no | names are answered inside the tunnel |
| Fingerprint | no | no CJK fonts and no DNT/GPC flag, which is what browser-fingerprint tests weigh |

Fatal failures block launching; advisory failures show amber and let you through.
A logged "Launch anyway" link appears when the gate refuses, so a wrong rule can
never lock you out of your own machine.

## Requirements

- Windows 10 or 11, Windows PowerShell 5.1 (built in).
- A tunnel that presents a TUN adapter named `Mihomo` (Clash Verge / Mihomo).
  The adapter name is one line in `Check-Tunnel.ps1` if yours differs.
- Your server's IPv4 address, added to the approved list (see below).

## Install

1. **Clone or copy this folder** anywhere, e.g. `C:\Tools\ai-hub`.
2. **Put your server's address in `exits.json`** â€” this is the only required edit:
   ```json
   { "exits": [ { "ip": "198.51.100.7", "label": "My server" } ] }
   ```
   That address is what the gate will accept. Anything else is a refusal.
3. **Make a shortcut** to `AIHub.exe` on your desktop (right-click â†’ Send to â†’
   Desktop). Do not pin `Start-AIHub.ps1` itself: the exe exists so that no console
   window is ever created, and pinning the script brings that problem back.
4. **Double-click it.** The window paints in about a second and the checks run in the
   background for roughly eight.

If the window says "Launch blocked", the strip names the check that failed. Press
RE-CHECK after fixing it. If nothing at all happens, read `gate-log.txt` in the same
folder: every start-up stage is stamped there with a process id.

### If your tunnel adapter is not called Mihomo

The first check looks for a network adapter named `Mihomo`. If yours is different,
change the name in `Check-Tunnel.ps1`:

```powershell
$ad = Get-NetAdapter -Name 'Mihomo' -ErrorAction SilentlyContinue
```

### What it needs from the tunnel

Full tunnel is assumed: every connection leaves through the tunnel. The checks look
for an adapter that owns the default route, a core process, and an exit address that
matches your approved list. Split-tunnel setups will fail the default-route check by
design, because traffic that bypasses the tunnel is exactly what this tool is for.
## Adding your own apps

Three ways, easiest first:

**Drag and drop.** Drag a program, a shortcut, a `.url` file, or a link straight from
your browser onto the window. ADD opens with the fields filled in; press ADD.

**The ADD button.** Pick a kind and the Target field tells you what it wants:

| Kind | Target | Example |
|---|---|---|
| Web page | a full address; `https://` is added for you | `example.org` |
| Program | full path to an .exe | `C:\Program Files\App\App.exe` |
| Store app | a Store AppID (`Get-StartApps` lists them) | `Claude_pzs8sxrjxfjjc!Claude` |
| Terminal | the command to run | `claude` |

Group is free text: a new group appears wherever its first tile was added.

**`apps.json`** â€” everything the ADD dialog does, by hand:

```json
{
  "name": "Claude",
  "note": "Desktop app",
  "kind": "appid",
  "target": "Claude_pzs8sxrjxfjjc!Claude",
  "group": "Desktop apps",
  "enabled": true
}
```

## Approved exits

`exits.json` is the source of truth. The **EXITS** button in the check panel adds and
removes addresses without editing files, with IPv4 validation and a guard that keeps
at least one. After changing the list, press **RE-CHECK**.

Keep it tight: every address on it is a place your traffic can leave from without the
gate noticing a change.

## Files

| File | What it is |
|---|---|
| `Start-AIHub.ps1` | the window, the tiles, the checks driver, drag and drop |
| `Check-Tunnel.ps1` | the 14 checks and the approved-exit list |
| `AIHub.exe` + `Launcher.cs` | a GUI-subsystem launcher so no console window ever exists |
| `apps.json` | the tiles |
| `exits.json` | the approved exits |
| `gate-log.txt` | every launch, refusal, override and added tile |

## Notes and limits

- The checks run **before** launch. If the tunnel dies while an app is already open,
  that app keeps running; this tool is a gate, not a firewall.
- The hub is PowerShell + WPF. A window hosted by `powershell.exe` is really that
  process, which is why the launcher exists: `AIHub.exe` starts PowerShell with
  `CREATE_NO_WINDOW`, so there is never a console window to close by accident.
- Brand marks in `assets/brand/` are the property of their owners and are used only
  to identify the app they belong to. See `NOTICE`.

## Licence

MIT for the code. Brand marks are not covered â€” see `NOTICE`.