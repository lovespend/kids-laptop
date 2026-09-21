# kids-laptop

[![shellcheck](https://github.com/lovespend/kids-laptop/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/lovespend/kids-laptop/actions/workflows/shellcheck.yml)

Scripts and a runbook for turning a Linux Mint (Cinnamon) laptop into a
child-safe machine: filtered internet that follows the laptop onto any
network, admin and bypass tools locked away from the child's account, and
settings that survive suspend, reboots and package upgrades.

## Contents

| File | What it is |
|---|---|
| [`bootstrap.sh`](bootstrap.sh) | Fast path for a clean install: runs every mechanical step in order and stops at the app review. |
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

### Clean install — the fast path

On a freshly installed machine, as the parent account:

```bash
git clone https://github.com/lovespend/kids-laptop.git
cd kids-laptop
sudo ./bootstrap.sh --child CHILD --profile PROFILE_ID
```

That runs every mechanical step in order — account checks, `systemd-resolved`,
the NextDNS CLI, DNS hardening, app-gate install and audit — and stops at the
one step that needs your judgement: reviewing which apps to lock. Then:

```bash
sudo nano /etc/app-gate/app-gate.list
sudo app-gate apply
```

`--dry-run` shows what it would do without changing anything. Every phase is
idempotent, so if it stops partway, fix the problem and run it again.

NextDNS is installed from their apt repository, so there's nothing to answer —
and the CLI then upgrades through apt with everything else. If that repository
is unreachable, bootstrap falls back to the interactive installer and puts the
answers you need on screen.

### Step by step

If you'd rather do it by hand, or you're setting up a machine that's already in
use, `RUNBOOK.md` covers the same ground in detail with a verification
checklist. In outline:

```bash
sudo ./kid-net-setup.sh CHILD
sudo ./app-gate.sh install CHILD PARENT
sudo app-gate audit     # review /etc/app-gate/app-gate.list
sudo app-gate apply
```
