#!/bin/bash
#
# kid-net-setup — make NextDNS filtering stick on a child's Linux Mint laptop.
#
#   sudo ./kid-net-setup.sh CHILD_USER
#
# Prerequisite: NextDNS CLI already installed and pointed at the child's
# profile (runbook step 3). This script then:
#   1. Stops NetworkManager handing out router/DHCP DNS (dispatcher re-asserts
#      127.0.0.1 on every connect / lease change, on any network)
#   2. Restarts NextDNS after every resume from suspend
#   3. Sets lid-close = suspend (system-wide fallback + child's Cinnamon session)
#   4. Firefox policy: DNS-over-HTTPS off and locked, NextDNS CA auto-trusted
#      in every profile (no manual cert import, block page works)
#
# Safe to re-run.
#
set -uo pipefail

die()  { echo "kid-net-setup: $*" >&2; exit 1; }
ok()   { echo "  [ok] $*"; }
note() { echo "  [!!] $*"; }

[ "$(id -u)" -eq 0 ] || die "run with sudo"
CHILD="${1:-}"
[ -n "$CHILD" ] || die "usage: sudo $0 CHILD_USER"
id "$CHILD" >/dev/null 2>&1 || die "no such user: $CHILD"
CHILD_HOME=$(getent passwd "$CHILD" | cut -d: -f6)

echo "== Pre-flight"
command -v nextdns >/dev/null || die "NextDNS CLI not found — do runbook step 3 first"

# systemd-resolved is not optional here. We set NetworkManager dns=none (so NM
# stops writing /etc/resolv.conf) and pin each link with resolvectl. Without
# resolved, nothing writes resolv.conf at all and the laptop silently keeps
# whatever DNS it last had — quite possibly the router's. Mint does not always
# enable resolved by default, so check before we change anything.
command -v resolvectl >/dev/null \
  || die "resolvectl not found — this script needs systemd-resolved (install it, then: sudo systemctl enable --now systemd-resolved)"
systemctl is-active --quiet systemd-resolved \
  || die "systemd-resolved is not running. Enable it first:
    sudo systemctl enable --now systemd-resolved
  then re-run this script. Nothing has been changed."
ok "systemd-resolved active"
systemctl is-enabled --quiet nextdns 2>/dev/null && ok "nextdns service enabled" \
  || note "nextdns service not enabled — check: systemctl status nextdns"
id -nG "$CHILD" | grep -qwE 'sudo|admin|wheel' \
  && note "$CHILD has admin rights — remove with: sudo deluser $CHILD sudo" \
  || ok "$CHILD is not an admin"

# ------------------------------------------------------------ 1. DNS pinning
echo "== DNS pinning"
install -d /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/90-kid-dns.conf <<'EOF'
[main]
dns=none
EOF
ok "NetworkManager: dns=none"

cat > /etc/NetworkManager/dispatcher.d/99-force-nextdns <<'EOF'
#!/bin/sh
# Force every real link to resolve via the local NextDNS proxy, overriding
# DNS servers handed out by DHCP or IPv6 router advertisements.
#
# NetworkManager discards dispatcher output, so anything worth knowing goes to
# the journal instead:  journalctl -t force-nextdns
IFACE="$1"; ACTION="$2"
[ -n "$IFACE" ] && [ "$IFACE" != "none" ] && [ "$IFACE" != "lo" ] || exit 0

pin() {
  out=$("$@" 2>&1) && return 0
  logger -t force-nextdns -p daemon.err "FAILED on $IFACE ($ACTION): $*${out:+ : $out}"
  return 1
}

case "$ACTION" in
  up|dhcp4-change|dhcp6-change|connectivity-change|reapply)
    pin resolvectl dns    "$IFACE" 127.0.0.1 || exit 1
    pin resolvectl domain "$IFACE" '~.'      || exit 1
    logger -t force-nextdns -p daemon.info "$IFACE ($ACTION): DNS pinned to 127.0.0.1"
    ;;
esac
EOF
chmod 755 /etc/NetworkManager/dispatcher.d/99-force-nextdns
ok "dispatcher hook installed"

# ------------------------------------------------------------ 2. resume hook
cat > /usr/lib/systemd/system-sleep/nextdns-resume <<'EOF'
#!/bin/sh
case "$1" in
  post) systemctl restart nextdns ;;
esac
EOF
chmod 755 /usr/lib/systemd/system-sleep/nextdns-resume
ok "resume hook installed"

# --------------------------------------------------------- 3. lid = suspend
echo "== Lid close"
install -d /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/50-lid-suspend.conf <<'EOF'
[Login]
HandleLidSwitch=suspend
HandleLidSwitchExternalPower=suspend
EOF
ok "system fallback set (active after reboot)"

if loginctl list-users --no-legend 2>/dev/null | awk '{print $2}' | grep -qx "$CHILD"; then
  note "$CHILD is logged in — log them out and re-run to set their Cinnamon lid action"
elif ! command -v dbus-launch >/dev/null; then
  note "dbus-launch missing — set lid action in $CHILD's Power Management manually"
else
  for k in lid-close-battery-action lid-close-ac-action; do
    runuser -u "$CHILD" -- env HOME="$CHILD_HOME" dbus-launch gsettings set \
      org.cinnamon.settings-daemon.plugins.power "$k" 'suspend' 2>/dev/null
  done
  v=$(runuser -u "$CHILD" -- env HOME="$CHILD_HOME" dbus-launch gsettings get \
      org.cinnamon.settings-daemon.plugins.power lid-close-battery-action 2>/dev/null)
  [ "$v" = "'suspend'" ] && ok "$CHILD's session: lid close = suspend" \
                         || note "couldn't confirm $CHILD's lid setting (got: ${v:-nothing})"
fi

# ------------------------------------------------------- 4. Firefox policy
echo "== Firefox"
CA=/usr/local/share/nextdns/NextDNS.cer
install -d -m 755 /usr/local/share/nextdns
if curl -fsSL https://nextdns.io/ca -o "$CA.tmp"; then
  mv "$CA.tmp" "$CA"; chmod 644 "$CA"; ok "NextDNS CA downloaded"
else
  rm -f "$CA.tmp"; note "couldn't download CA — block page will show cert errors"
fi

POL=/etc/firefox/policies/policies.json
install -d /etc/firefox/policies
[ -f "$POL" ] && ! grep -q 'kid-net-setup' "$POL" && cp "$POL" "$POL.bak.$(date +%s)" \
  && note "existing policies.json backed up — merge anything you need back in"
cat > "$POL" <<EOF
{
  "policies": {
    "_comment": "managed by kid-net-setup",
    "DNSOverHTTPS": { "Enabled": false, "Locked": true },
    "Certificates": { "Install": ["$CA"] }
  }
}
EOF
chmod 644 "$POL"
ok "policy written: DoH off+locked, NextDNS CA trusted"
for d in /usr/lib/firefox/distribution /usr/lib/firefox-esr/distribution; do
  [ -f "$d/policies.json" ] && note "$d/policies.json also exists — check about:policies shows ours"
done
command -v flatpak >/dev/null && flatpak list --app 2>/dev/null | grep -qi firefox \
  && note "Flatpak Firefox detected — it ignores /etc/firefox; use the .deb Firefox"

# ----------------------------------------------------------------- restart
echo "== Applying"
systemctl restart NetworkManager
sleep 3
# NM restart doesn't always fire 'up' for existing links — pin them directly
for dev in $(nmcli -t -f DEVICE,STATE device 2>/dev/null | awk -F: '$2=="connected"{print $1}'); do
  /etc/NetworkManager/dispatcher.d/99-force-nextdns "$dev" up
done
systemctl restart nextdns
sleep 2
echo
resolvectl status | grep -E '^Link|DNS Servers' | sed 's/^/  /'
echo
echo "Every link above should list 127.0.0.1 only."
echo "Reboot once (lid fallback), then run the verification checklist in the runbook."
