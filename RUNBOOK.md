# Kid's Linux Mint Laptop — Filtering & Lockdown Runbook

Repeatable setup for a child's Linux Mint (Cinnamon) laptop: filtered internet via NextDNS, admin tools locked away, and settings that survive suspend, reboots and package upgrades.

Throughout, **CHILD** is the kid's username and **PARENT** is the parent's admin account. Substitute real names. Never type the words literally with angle brackets around them — `<` and `>` are shell operators.

---

## How it fits together

Four layers, each covering a gap the others leave:

1. **Accounts.** The child has a standard (non-admin) account. Every other control relies on this; an admin child can undo all of it.
2. **DNS filtering.** The NextDNS CLI runs on the laptop as a local resolver (127.0.0.1) tied to the child's NextDNS profile. It works on any network — home, school, friends' houses — because it lives on the machine, not the router.
3. **Keeping DNS pinned.** Out of the box, NetworkManager hands the router's DNS to each Wi-Fi link on every connect and after every resume, which silently bypasses NextDNS. `kid-net-setup.sh` installs hooks that re-pin DNS to 127.0.0.1 and restart NextDNS after suspend. It also sets a locked Firefox policy that stops the browser using its own DNS-over-HTTPS, and auto-trusts the NextDNS certificate so blocked sites show a block page instead of a cert error.
4. **App gating.** `app-gate.sh` hides admin and bypass tools from the child's menu *and* blocks the binaries at the filesystem level, so relaunching them another way doesn't work. An apt hook re-applies the locks after upgrades.

The parent keeps full access throughout: the parent account is in the `gatedapps` group, and a text console (Ctrl+Alt+F2) always works regardless of what's locked.

---

## What you need

- The laptop with Linux Mint (Cinnamon) installed, and the parent's admin account
- A free NextDNS account (nextdns.io) — the free tier is ample for one device
- The kit: `RUNBOOK.md`, `kid-net-setup.sh`, `app-gate.sh`
- About 45 minutes, most of it reviewing the app list

---

## Step 1 — Accounts

Log in as PARENT. Create the child's account if it doesn't exist (System Settings → Users and Groups), as a **Standard** user. Then confirm they're not an admin:

```bash
groups CHILD
```

If `sudo` appears in the output, remove it:

```bash
sudo deluser CHILD sudo
```

## Step 2 — NextDNS profile (web dashboard)

At my.nextdns.io, create a new profile for the child, then configure:

- **Parental Control:** block the categories you want (adult content, gambling, dating, etc.). Turn on SafeSearch and YouTube Restricted Mode.
- **Settings:** turn on **Block Page**. This needs the CA certificate, which Step 5 handles automatically.
- Note the **profile ID** (six characters, shown on the Setup tab).

The model here is "block known-bad categories, allow the rest", with per-site allow/deny exceptions from the dashboard. True whitelist-only filtering was tried and abandoned: every site needs dozens of domains discovered by hand, forever.

## Step 3 — Install the NextDNS CLI

In a terminal on the laptop, as PARENT:

```bash
sh -c "$(curl -sL https://nextdns.io/install)"
```

Choose **Install**. When prompted:

- Enter the child's profile ID
- Answer yes to reporting device name/model
- Answer yes to auto-activate / setting it as the system resolver

Confirm the service is running and enabled:

```bash
systemctl status nextdns
```

## Step 4 — Copy the kit to the parent's account

Put the kit somewhere only PARENT can read, for example:

```bash
mkdir -p ~/kid-kit && chmod 700 ~/kid-kit
# copy the three files in, then:
chmod +x ~/kid-kit/*.sh
```

## Step 5 — DNS hardening, lid behaviour, Firefox policy

Log the child **out** first. The script sets their lid-close behaviour, which it can't do while they're signed in. Then:

```bash
sudo ~/kid-kit/kid-net-setup.sh CHILD
```

The script:

- pins DNS to 127.0.0.1 on every network link, overriding router and IPv6 DNS
- restarts NextDNS after every resume from suspend
- sets closing the lid to suspend, both for the child's session and as a system fallback
- writes a Firefox policy that turns DNS-over-HTTPS off and locks it, and trusts the NextDNS CA in every profile

Each check prints `[ok]` or `[!!]`. Fix any `[!!]` lines before moving on.

**Reboot once** after this step, so the lid fallback takes effect.

## Step 6 — App gating: install and audit

```bash
sudo ~/kid-kit/app-gate.sh install CHILD PARENT
sudo app-gate audit
```

The install command copies the script to `/usr/local/sbin/app-gate` (so from here on it's just `sudo app-gate ...`). It also creates the `gatedapps` group, adds PARENT to it, and installs the apt re-apply hook.

The audit writes `/etc/app-gate/app-gate.list`. Open it with:

```bash
sudo nano /etc/app-gate/app-gate.list
```

Each line reads `VERDICT | desktop-id | binary  # App name`. The verdicts are:

| Verdict | Effect |
|---|---|
| `KEEP` | Visible and runnable |
| `LOCK` | Hidden from the menu and execution blocked |
| `ASK` | Unrecognised; behaves as KEEP until you decide |
| `IGNORE` | Never touched |

Review in this order:

1. **UNRECOGNISED block.** Decide each one.
2. **LOCK block.** Make sure nothing she needs is in it.
3. **KEEP block.** A quick skim for anything that shouldn't be there.

The default categorisation, tuned for an 11-year-old:

- **Locked:** disk and partition tools; package managers, updates and software sources; users, drivers and firewall; Timeshift; all terminals; development tools; VMs; remote-desktop tools.
- **Locked because they bypass the filtering:** every browser except Firefox, VPN clients and torrent clients.
- **Kept:** Firefox, the file manager, text editor, LibreOffice, drawing and creative apps, media players, PDF and image viewers, calculator, screenshot tool, archive manager, accessibility tools, education apps and games.
- **Kept on purpose:** Cinnamon System Settings. Locking it also takes away Wi-Fi setup, displays, printers and accessibility options. Lock it only if you're happy to handle those changes for her from the parent account.

A binary shown as `-` means the script couldn't safely identify the executable, for example a `sh -c` launcher. A LOCK on that line only hides it from the menu.

## Step 7 — Apply

```bash
sudo app-gate apply
```

Log PARENT out and back in once, so the new group membership takes effect.

## Step 8 — Verify

Log in as CHILD and check each item:

- [ ] `https://test.nextdns.io` in Firefox shows NextDNS **and the correct profile ID**
- [ ] A site in a blocked category shows the NextDNS block page, not a certificate error
- [ ] `about:policies` in Firefox lists `DNSOverHTTPS` and `Certificates` as active
- [ ] Locked apps are missing from the menu
- [ ] The terminal won't open for the child
- [ ] Close the lid for a minute, reopen, and recheck `test.nextdns.io`
- [ ] Turn Wi-Fi off and on, then recheck

Then, from a PARENT terminal:

```bash
resolvectl status          # every link: DNS Servers 127.0.0.1 only
sudo app-gate status       # Drift: 0
```

---

## Maintenance

| When | Do |
|---|---|
| After a large upgrade | Nothing needed; the apt hook re-applies the locks. `sudo app-gate status` confirms it. |
| New apps installed | Run `sudo app-gate audit` (your existing choices are kept), review the **NEW** block, then `sudo app-gate apply` |
| Unlock an app | Edit the list and change `LOCK` to `KEEP`, then `sudo app-gate apply` |
| A site is wrongly blocked or allowed | Adjust the allow/deny lists in the NextDNS dashboard. No laptop changes needed. |
| Undo all app gating | `sudo app-gate revert` (keeps the list) or `sudo app-gate uninstall` (removes everything) |

Each audit backs up the previous list to `/etc/app-gate/app-gate.list.bak.*`.

---

## Troubleshooting

**Filtering stops working after suspend or reconnecting.** Check `resolvectl status`. If the Wi-Fi link lists the router's IP or an IPv6 address, the DNS pin hook didn't run. Re-run `kid-net-setup.sh`. If the link shows 127.0.0.1 but lookups fail, run `sudo systemctl restart nextdns` and check `nextdns log`.

**Filtering works for a while, then drifts back without a suspend.** IPv6 router advertisements may be refreshing DNS independently of NetworkManager's events. Add a systemd timer that re-runs the dispatcher hook every few minutes.

**Block page shows a certificate error.** Check `about:policies` in Firefox. If the policy isn't listed, another `policies.json` under `/usr/lib/firefox/distribution/` may be taking precedence, or Firefox is a Flatpak build, which ignores `/etc/firefox`. Use the .deb Firefox.

**"Private key" error when importing the cert by hand.** It was imported under *Your Certificates* instead of *Authorities*. With the Firefox policy in place, manual import isn't needed.

**Locked out of a terminal.** Press Ctrl+Alt+F2 for a text console, log in as PARENT, and Ctrl+Alt+F7 to return to the desktop. Or use Switch User to reach the parent's desktop session.

**PARENT can't open a locked app.** PARENT hasn't logged out and back in since the first `apply`. Check `id PARENT` includes `gatedapps`.

**`chown: invalid group 'CHILD:CHILD'`.** This was an old script bug, fixed in this version.

---

## What this doesn't protect against

- **Physical access.** Booting a live USB, or resetting a password from recovery mode. If that's a concern later, set a BIOS/UEFI password and disable USB boot.
- **Other devices.** A phone, tablet or console on the same Wi-Fi. They need their own filtering, either NextDNS configured on the device or filtering at the router.
- **Portable apps.** Anything downloaded into the child's home folder and run from there, such as an AppImage. `app-gate` only gates installed apps. Blocking execution in home directories is possible but a much bigger step.
- **A determined teenager.** This setup raises the bar well above casual and accidental access. It isn't a security boundary against someone actively working to get around it. Revisit the setup as the child gets older; network-level enforcement on the router is the next step up.
