# Clean IP Checker â€” and the AI Hub

Two things live here:

- **AI Hub** (`ai-hub/`) â€” a Windows launcher that verifies your tunnel exit before it
  opens Claude, ChatGPT, Codex or anything else you add. One window, no installer, no
  background service. See [ai-hub/README.md](ai-hub/README.md).
- **Clean IP Checker** â€” the web tool this repository is named for.

## AI Hub in one paragraph

It runs 14 checks against your machine and your tunnel â€” adapter, default route, core,
exit address, WebRTC, IPv6, DNS, reputation, and whether the AI vendors see the same
exit â€” and refuses to open anything if a fatal one fails. Everything else is a tile:
drop a program or a link on the window and it is added.