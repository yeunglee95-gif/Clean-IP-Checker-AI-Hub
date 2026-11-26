# AI Hub

A Windows front door for Claude, ChatGPT, Codex â€” and anything else you add. It
verifies your tunnel before it opens anything, so a broken or leaking proxy shows up
as a refusal instead of a quiet connection from your real address.

One window. No installer, no background service, no admin rights. Delete the folder
and it is gone.

## What it does

- **14 checks** against the machine and the tunnel: adapter, default route, core,
  exit IP, WebRTC, IPv6, DNS, IP reputation, whether the AI vendors see the same exit,
  country, locale, timezone, exit stability, fingerprint.
- **Refuses when a fatal check fails**, shows amber for advisory ones, and keeps a
  logged "launch anyway" link so a wrong rule can never lock you out.
- **Adds anything in one gesture**: drag a program, a shortcut, a `.url` file or a
  link from your browser onto the window.
- **Approved exits live in a file** and are edited from the app, not by editing code.

Full documentation: [ai-hub/README.md](ai-hub/README.md).

## Quick start

```
git clone https://github.com/yeunglee95-gif/ai-hub
cd ai-hub\ai-hub
```

Put your server's IPv4 address in `exits.json`, then run `AIHub.exe`. That is it.

## Requirements

Windows 10/11 with Windows PowerShell 5.1 and a Clash Verge / Mihomo tunnel that
creates an adapter named `Mihomo`.

## Licence

MIT for the code. Brand marks under `ai-hub/assets/brand/` are excluded â€” see
[ai-hub/NOTICE](ai-hub/NOTICE).