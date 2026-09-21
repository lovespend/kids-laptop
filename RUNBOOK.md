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
- `systemd-resolved` running on the laptop (see Step 0)
- A free NextDNS account (nextdns.io) — the free tier is ample for one device
- The kit: `RUNBOOK.md`, `bootstrap.sh`, `kid-net-setup.sh`, `app-gate.sh`
- About 45 minutes by hand, most of it reviewing the app list — or about 10 plus the review via the fast path below

---

## The fast path

On a clean install, `bootstrap.sh` runs steps 0 to 6 back to back and stops at the app review. Do Step 2 (the NextDNS profile) and Step 4 (getting the kit onto the laptop) first, then:

```bash
sudo ./bootstrap.sh --child CHILD --profile PROFILE_ID
```

You still do the review in Step 6 and the verification in Step 8 yourself. Add `--dry-run` to see what it would do without changing anything. Every phase is idempotent, so a failed run can be fixed and re-run.

The rest of this document is the same ground done by hand — worth reading either way, since it explains what each piece is for and how to verify it.

---

## Step 0 — Check systemd-resolved

Everything in Step 5 depends on this, so check it before you start:

```bash
systemctl is-active systemd-resolved
```

If that prints `active`, move on. If not, enable it:

```bash
sudo systemctl enable --now systemd-resolved
```

Why it matters: Step 5 tells NetworkManager to stop managing DNS (`dns=none`) and pins each network link to the local NextDNS resolver using `resolvectl`, which is systemd-resolved's tool. Mint doesn't always have resolved enabled. Without it, NetworkManager stops writing `/etc/resolv.conf` and nothing replaces it, so the laptop quietly carries on using whatever DNS it last had — very likely the router's, with no filtering. `kid-net-setup.sh` refuses to run if resolved isn't active, so you can't get into that state by accident, but it's quicker to fix now.

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

At my.nextdns.io, create a new profile for the child and note the **profile ID** — six characters, on the Setup tab. You need it in Step 3.

Then work through the tabs. What follows is a recommended baseline for a child of around 11; adjust to your own judgement, and see *Tuning it* below for what to change as she gets older. NextDNS move things around in the dashboard from time to time, so match these by meaning rather than expecting the labels to line up exactly.

### Security — turn it all on

Nothing here is a parenting decision, so there's little reason to leave any of it off:

| Setting | Why |
|---|---|
| Threat Intelligence Feeds | Known malicious domains |
| AI-Driven Threat Detection | Catches what the feeds haven't listed yet |
| Google Safe Browsing | Phishing and malware |
| Cryptojacking Protection | Mining scripts on compromised sites |
| DNS Rebinding Protection | Attacks that pivot to devices on your home network |
| IDN Homograph Attacks | Lookalike domains using non-Latin characters |
| Typosquatting Protection | `youtybe.com` and friends — genuinely useful for a child who mistypes |
| DGA Protection | Malware phoning home to generated domains |
| Block Newly Registered Domains | Scams and throwaway bypass sites are usually days old |
| Block Parked Domains | Ad-farm placeholders |
| Block CSAM | Leave on |

Two carry a false-positive cost worth knowing about. **Newly Registered Domains** will occasionally block something legitimate that has just launched. **Block Dynamic DNS Hostnames** stops `no-ip`-style hostnames, which is a real bypass route, but also breaks some game servers and self-hosted things. Turn both on, and if something breaks, check the logs before assuming the site is at fault.

### Privacy

Enable the **NextDNS Ads & Trackers Blocklist**. That one is well-maintained and rarely breaks anything.

Resist stacking three or four more blocklists on top. Each one adds breakage you'll have to diagnose, and a filtered laptop that keeps breaking is one she'll want to get around. The native tracking protection options are aimed at Windows, Apple and Samsung devices and do nothing useful on Linux.

### Parental Control — the part that matters

**Categories.** Block Porn, Gambling, Dating, Piracy, Social Networks and Video Streaming.

Blocking Video Streaming wholesale closes the long tail — the streaming sites nobody has heard of and NextDNS doesn't list individually. The services you *do* want then come back through on a schedule, which costs you nothing to maintain; see *Allowing a service back through* below.

**Services.** Per-app toggles, more precise than the categories. Block TikTok, Snapchat, Instagram, Twitch and Discord. Leave Roblox or Minecraft alone if she plays them.

**YouTube.** Use the YouTube *service* toggle to block it, not a denylist entry. YouTube isn't one domain — it's `youtube.com`, `youtu.be`, `ytimg.com`, `googlevideo.com`, `youtubei.googleapis.com` and more, and the service toggle tracks all of them. A hand-written denylist entry will leave gaps.

Know what this costs before you do it: embedded YouTube players break everywhere, including on sites you'd want to work — BBC Bitesize, school pages, help articles. That's not a bug in the setup, it's the actual consequence, and it's the most likely source of "this site is broken" complaints. Decide it deliberately rather than discovering it in homework week.

**Block Bypass Methods.** Turn this on. It blocks VPN, proxy and Tor services at the DNS level, and it is the single highest-value toggle on the page — "how to get past wifi blocking" is the first thing anyone searches. It pairs directly with `app-gate` locking the VPN and browser binaries: one stops her installing a bypass tool, this stops the ones she can reach in a browser.

**SafeSearch.** On. Forces the safe variants of Google, Bing and DuckDuckGo.

**YouTube Restricted Mode.** Irrelevant if you've blocked YouTube outright — it only filters a YouTube you can still reach. Leave it on anyway: it costs nothing and it's the safety net if the service toggle is ever turned off.

**Recreation Time.** Optional. Lets you put games and social categories on a schedule — off during school hours, off after bedtime — rather than blocking them outright. Often a better answer than a flat block for something she'd otherwise resent.

### Allowing a service back through — use the schedule, not the allowlist

With Video Streaming blocked as a category, the way to let one service through is **not** an allowlist entry. Instead:

1. Find the service under **Parental Control → Services** and block it explicitly.
2. On that same entry, set **allow this service via schedule** (Recreation Time).

The scheduled window overrides the category block, and the service works during it. NextDNS keeps the domain list for that service up to date, so there is nothing for you to maintain — no chasing CDN hosts, no allowlist entries, nothing to re-fix when the service moves infrastructure.

This is how Disney+ gets through. If you want a service available all the time rather than in a window, give it a schedule covering the whole week.

Two things fall out of this that are worth having on purpose:

- **It's time-boxed.** A window you chose beats an always-on allowance, and it's a much easier conversation than an outright block.
- **It doesn't touch your security filtering.** This is a Parental Control mechanism, so it grants an exception within parental controls only. An Allowlist entry is the blunter instrument — see below.

**Only use the Allowlist as a last resort, and keep entries narrow.** An allowlist entry covers the domain *and its subdomains*, and takes precedence over blocking — including the Security tab. So allowing a shared-infrastructure domain because a video wouldn't play (`amazonaws.com`, `akamaized.net`, `cloudfront.net` and the like) punches a hole far wider than the service you were fixing, and it will still be quietly carrying malware domains months later. If something only works by allowing shared infrastructure, that's a sign to stop, not to widen the hole.

### When the service isn't on NextDNS's list

NextDNS's service list is US-centric, and **BBC iPlayer isn't on it**. No service entry means no schedule to hang an exception on, so the method above doesn't apply.

**Check whether it's actually blocked first.** The Video Streaming category is built from NextDNS's own service definitions. A service they don't recognise may well not be in the category either — in which case iPlayer already works and there is nothing to solve. Open it on the child's laptop and try to play something before doing anything else.

If it *is* blocked, the Allowlist is the only route left, and this is the case it exists for. Do it from the logs rather than from guesswork:

1. Logs on. Reproduce the failure on the laptop.
2. Read the **Logs** tab for the blocked lookups.
3. Allow them — **as full hostnames, not apex domains**.

That last point is the whole game. `bbc.co.uk` and `bbci.co.uk` are BBC-owned and safe enough to allow at the apex. Streaming itself usually comes from a shared CDN, and `akamaized.net` or `llnwd.net` at the apex would open every customer on that CDN, including the malicious ones. Allow the specific hostname the log names — `something.bbcfmt.hs.llnwd.net`, not `llnwd.net` — and you get iPlayer without the hole. If a hostname turns out to rotate, allow the narrowest parent that is still clearly BBC's.

The cost is that this one needs revisiting if the BBC moves hosts, which is exactly the maintenance the schedule method avoids. It's worth asking NextDNS to add iPlayer as a service; they take requests, and it would remove this section.

> Checked against the live dashboard, September 2026. NextDNS move things around, so if the schedule override stops behaving as described, re-check it before assuming the setup is broken.

### Settings — block page and logging

**Block Page: on.** Without it, a blocked site fails as a confusing network error; with it, she gets a page telling her it was blocked. Much easier to live with, and much easier to debug. It needs the NextDNS certificate to be trusted, which Step 5 handles.

**Logging is a decision, not a default.** Logs make the first fortnight far easier — when something is wrongly blocked, the log shows you the exact domain and you allowlist it in seconds. They also mean you're keeping a record of your child's browsing, which is a parenting choice rather than a technical one. A reasonable middle: turn logs on while you settle the setup, keep retention short, pick the storage region nearest you, then decide deliberately whether to keep them.

Whatever you decide, tell her the laptop is filtered and roughly how. Discovering it later feels like being spied on; being told up front is just a house rule.

### The filtering model

"Block known-bad categories, allow the rest", with per-site exceptions from the Allowlist and Denylist tabs. True whitelist-only filtering was tried and abandoned: every site needs dozens of domains discovered by hand, forever.

### Tuning it

Expect to adjust in the first fortnight. Wrongly blocked sites are a dashboard change and nothing on the laptop — see *Maintenance*. If you find yourself making exceptions constantly for one category, unblock the category and use per-site denies instead.

As she gets older the things to relax first are the YouTube block and the Social Networks category. The two to keep longest are Block Bypass Methods and the Security tab.

## Step 3 — Install the NextDNS CLI

Mint is Debian-based, so use NextDNS's apt repository. Upgrades then come through apt with everything else, and there's nothing interactive to answer. As PARENT:

```bash
sudo curl -fsSL https://repo.nextdns.io/nextdns.gpg -o /usr/share/keyrings/nextdns.gpg
echo "deb [signed-by=/usr/share/keyrings/nextdns.gpg] https://repo.nextdns.io/deb stable main" | sudo tee /etc/apt/sources.list.d/nextdns.list
sudo apt update
sudo apt install nextdns
```

Then configure it, substituting the profile ID from Step 2:

```bash
sudo nextdns install -profile PROFILE_ID -report-client-info -auto-activate
```

If that reports an unknown flag, your build uses the newer name — swap `-profile` for `-config`. Getting this wrong is worth catching: the service will start either way, but DNS goes out unfiltered.

<details>
<summary>Alternative: the interactive installer</summary>

```bash
sh -c "$(curl -sL https://nextdns.io/install)"
```

Choose **Install**. When prompted:

- Enter the child's profile ID
- Answer yes to reporting device name/model
- Answer yes to auto-activate / setting it as the system resolver

Upgrades are then handled with `sudo nextdns upgrade` rather than apt. Pin a specific build with `NEXTDNS_VERSION=master/SNAPSHOT-0214daf` before the command. Add `DEBUG=1` if you need a transcript for NextDNS support.
</details>

Confirm the service is running and enabled:

```bash
systemctl status nextdns
```

The CLI may warn that client discovery is disabled because it's listening on a loopback address only, so devices show up in the dashboard without names. That's expected here and doesn't affect filtering — this profile has one device on it, the laptop itself.


## Step 4 — Get the kit onto the laptop

As PARENT, clone it somewhere only they can read:

```bash
git clone https://github.com/lovespend/kids-laptop.git ~/kid-kit
chmod 700 ~/kid-kit
```

Or, if the laptop has no git, copy the four files across by hand and make the scripts executable:

```bash
mkdir -p ~/kid-kit && chmod 700 ~/kid-kit
# copy RUNBOOK.md, bootstrap.sh, kid-net-setup.sh and app-gate.sh in, then:
chmod +x ~/kid-kit/*.sh
```

The scripts expect to sit next to each other — `bootstrap.sh` looks for the other two alongside itself.

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
- [ ] A VPN or proxy provider's site is blocked, confirming Block Bypass Methods is live
- [ ] YouTube is blocked, including `youtu.be` and the mobile site
- [ ] BBC iPlayer and Disney+ both actually play a video, not just load their front page — inside their scheduled window
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
| After a large upgrade | Nothing needed; the apt hook re-applies the locks, and the NextDNS CLI upgrades with everything else. `sudo app-gate status` confirms it. |
| New apps installed | Run `sudo app-gate audit` (your existing choices are kept), review the **NEW** block, then `sudo app-gate apply` |
| Unlock an app | Edit the list and change `LOCK` to `KEEP`, then `sudo app-gate apply` |
| A site is wrongly blocked or allowed | Adjust the allow/deny lists in the NextDNS dashboard. No laptop changes needed. |
| Disney+ stops playing | Check its schedule first — most often it's simply outside the window. NextDNS maintains the domains, so a CDN move isn't yours to fix. |
| iPlayer stops playing | It has no service entry, so it rides on allowlisted hostnames. Reproduce it with the Logs tab open and allow the new hostname — narrowly, never a bare CDN apex. |
| Undo all app gating | `sudo app-gate revert` (keeps the list) or `sudo app-gate uninstall` (removes everything) |

Each audit backs up the previous list to `/etc/app-gate/app-gate.list.bak.*`.

---

## Troubleshooting

**Filtering stops working after suspend or reconnecting.** Check `resolvectl status`. If the Wi-Fi link lists the router's IP or an IPv6 address, the DNS pin hook didn't run. See what it did with:

```bash
journalctl -t force-nextdns -n 30
```

Every run logs either the link it pinned or the command that failed. No entries at all means NetworkManager never called the hook — re-run `kid-net-setup.sh`. If the link shows 127.0.0.1 but lookups fail, run `sudo systemctl restart nextdns` and check `nextdns log`.

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
- **Scripting inside apps she keeps.** LibreOffice Basic (Tools → Macros) has a `Shell()` function, and GIMP has a Script-Fu console. Both can run arbitrary commands as her. The `app-gate` locks still apply — a command she launches this way is blocked the same as one launched from the menu — but it is a way to run anything *not* locked, including files she has downloaded into her home folder. Locking LibreOffice isn't the answer; this is simply another reason the setup isn't a security boundary.
- **A determined teenager.** This setup raises the bar well above casual and accidental access. It isn't a security boundary against someone actively working to get around it. Revisit the setup as the child gets older; network-level enforcement on the router is the next step up.
