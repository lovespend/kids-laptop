# kids-laptop

Scripts and a runbook for turning a Linux Mint (Cinnamon) laptop into a
child-safe machine: filtered internet that follows the laptop onto any
network, admin and bypass tools locked away from the child's account, and
settings that survive suspend, reboots and package upgrades.

## Contents

| File | What it is |
|---|---|
| [`RUNBOOK.md`](RUNBOOK.md) | Start here. Step-by-step setup, verification checklist, maintenance and troubleshooting. |
| [`kid-net-setup.sh`](kid-net-setup.sh) | Pins DNS to the local NextDNS resolver on every link, re-asserts it after suspend and reconnects, sets lid-close behaviour, and locks Firefox's DNS-over-HTTPS off while trusting the NextDNS CA. |
| [`app-gate.sh`](app-gate.sh) | Audits installed desktop apps, then hides the ones you choose from the child's menu and blocks their binaries at the filesystem level. Re-applies itself after apt upgrades. |

## The short version

Four layers, each covering a gap the others leave:

1. **A standard (non-admin) child account** — everything else depends on it.
2. **NextDNS CLI as a local resolver**, tied to the child's filtering profile.
   It lives on the laptop, so it works on any Wi-Fi.
3. **DNS pinning** (`kid-net-setup.sh`), because NetworkManager otherwise
   hands the router's DNS back on every connect and resume.
4. **App gating** (`app-gate.sh`), hiding and blocking admin tools, terminals,
   other browsers, VPNs and torrent clients.

The parent keeps full access: the parent account is in the `gatedapps` group,
and a text console (Ctrl+Alt+F2) always works.

This raises the bar well above casual and accidental access. It is not a
security boundary against someone actively working around it — see
*What this doesn't protect against* at the end of the runbook.

## Usage

Read `RUNBOOK.md` first. In outline, as the parent account:

```bash
sudo ./kid-net-setup.sh CHILD
sudo ./app-gate.sh install CHILD PARENT
sudo app-gate audit     # review /etc/app-gate/app-gate.list
sudo app-gate apply
```
