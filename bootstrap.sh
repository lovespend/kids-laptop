#!/bin/bash
#
# bootstrap — take a clean Linux Mint install to the app-gate review step.
#
#   sudo ./bootstrap.sh --child CHILD [--parent PARENT] [--profile PROFILE_ID]
#
# Runs runbook steps 0-6 in order, stopping where a human has to make
# decisions: reviewing the app list. Everything before that is mechanical.
#
# Each phase is idempotent — if something fails halfway, fix it and re-run.
# Nothing here is undone by re-running.
#
# What it deliberately does NOT do:
#   * Decide which apps to lock. That's the review step, and it's yours.
#   * Choose NextDNS filtering categories. That's the web dashboard.
#   * Set a BIOS password or disable USB boot. Physical access is out of scope
#     for this kit (see RUNBOOK.md, "What this doesn't protect against").
#
set -uo pipefail

HERE=$(cd -- "$(dirname -- "$(readlink -f "$0")")" && pwd)
CHILD=""; PARENT=""; PROFILE=""; ASSUME_YES=0; DRY_RUN=0

# ------------------------------------------------------------------- output
c_ok=""; c_bad=""; c_hd=""; c_off=""
if [ -t 1 ]; then c_ok=$'\033[32m'; c_bad=$'\033[31m'; c_hd=$'\033[1m'; c_off=$'\033[0m'; fi
phase() { printf '\n%s== %s%s\n' "$c_hd" "$*" "$c_off"; }
ok()    { printf '  %s[ok]%s %s\n' "$c_ok" "$c_off" "$*"; }
note()  { printf '  %s[!!]%s %s\n' "$c_bad" "$c_off" "$*"; }
skip()  { printf '  [--] %s\n' "$*"; }
die()   { printf '%sbootstrap: %s%s\n' "$c_bad" "$*" "$c_off" >&2; exit 1; }

run() {
  if [ "$DRY_RUN" -eq 1 ]; then printf '  [dry-run] %s\n' "$*"; return 0; fi
  "$@"
}

# Ask a yes/no question. --yes answers yes to all of them.
confirm() {
  [ "$ASSUME_YES" -eq 1 ] && { printf '  %s [auto-yes]\n' "$1"; return 0; }
  [ -t 0 ] || { note "not a terminal and --yes not given — skipping: $1"; return 1; }
  local reply
  read -r -p "  $1 [y/N] " reply
  [ "$reply" = "y" ] || [ "$reply" = "Y" ]
}

usage() {
  sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  --child NAME     the child's account (required)
  --parent NAME    the parent's admin account (default: the account running sudo)
  --profile ID     NextDNS profile ID, used only if the CLI is already installed
                   but not yet configured
  --yes            don't ask for confirmation on any step
  --dry-run        print what would happen, change nothing
  -h, --help       this text

Environment:
  NEXTDNS_VERSION  pin the build fetched by the interactive installer, e.g.
                   master/SNAPSHOT-0214daf. Only used if the apt repository
                   path fails; apt installs the current stable package.
EOF
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --child)   CHILD="${2:-}";   shift 2 || die "--child needs a value";;
    --parent)  PARENT="${2:-}";  shift 2 || die "--parent needs a value";;
    --profile) PROFILE="${2:-}"; shift 2 || die "--profile needs a value";;
    --yes|-y)  ASSUME_YES=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) usage;;
    *) die "unknown option: $1 (try --help)";;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -n "$CHILD" ] || die "usage: sudo $0 --child CHILD [--parent PARENT]  (try --help)"
PARENT="${PARENT:-${SUDO_USER:-}}"
[ -n "$PARENT" ] || die "couldn't work out the parent account — pass --parent PARENT"
[ "$CHILD" != "$PARENT" ] || die "child and parent must be different accounts"

for f in kid-net-setup.sh app-gate.sh; do
  [ -f "$HERE/$f" ] || die "$f not found next to this script — run it from a clone of the repo"
done
[ "$DRY_RUN" -eq 1 ] && printf '%s(dry run — nothing will be changed)%s\n' "$c_hd" "$c_off"

# ----------------------------------------------------------- 0. environment
phase "Environment"
. /etc/os-release 2>/dev/null || true
case "${ID:-}${ID_LIKE:-}" in
  *linuxmint*|*ubuntu*|*debian*) ok "${PRETTY_NAME:-Debian-family system}";;
  *) note "${PRETTY_NAME:-unknown OS} — this kit targets Linux Mint; continuing anyway";;
esac
for c in curl systemctl resolvectl nmcli getent runuser; do
  command -v "$c" >/dev/null || die "missing required command: $c"
done
ok "required commands present"

# ------------------------------------------------------------- 1. accounts
phase "Accounts (runbook step 1)"
if ! id "$PARENT" >/dev/null 2>&1; then
  die "no such user: $PARENT"
fi
id -nG "$PARENT" | grep -qwE 'sudo|admin|wheel' \
  && ok "$PARENT is an admin" \
  || note "$PARENT is not in sudo/admin — they won't be able to manage this later"

if id "$CHILD" >/dev/null 2>&1; then
  ok "$CHILD exists"
else
  note "$CHILD does not exist"
  if confirm "Create the account '$CHILD' now? (adduser will prompt for a password)"; then
    run adduser "$CHILD" || die "adduser failed"
    ok "created $CHILD"
  else
    die "create $CHILD first (System Settings -> Users and Groups, Standard account), then re-run"
  fi
fi

if id -nG "$CHILD" | grep -qwE 'sudo|admin|wheel'; then
  note "$CHILD has admin rights — every other control here depends on removing them"
  if confirm "Remove $CHILD from the sudo/admin groups now?"; then
    for g in sudo admin wheel; do
      id -nG "$CHILD" | grep -qw "$g" && run deluser "$CHILD" "$g" >/dev/null
    done
    id -nG "$CHILD" | grep -qwE 'sudo|admin|wheel' \
      && die "couldn't demote $CHILD — sort this out before continuing" \
      || ok "$CHILD demoted to a standard account"
  else
    die "refusing to continue with an admin child account"
  fi
else
  ok "$CHILD is a standard (non-admin) account"
fi

# ------------------------------------------------------ 2. systemd-resolved
phase "systemd-resolved (runbook step 0)"
if systemctl is-active --quiet systemd-resolved; then
  ok "already active"
else
  note "not active — kid-net-setup.sh needs it"
  if ! systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1; then
    confirm "Install the systemd-resolved package?" \
      && { run apt-get update -qq && run apt-get install -y systemd-resolved; } \
      || die "systemd-resolved is required — see RUNBOOK.md step 0"
  fi
  run systemctl enable --now systemd-resolved || die "couldn't start systemd-resolved"
  systemctl is-active --quiet systemd-resolved || [ "$DRY_RUN" -eq 1 ] \
    || die "systemd-resolved still isn't active — see RUNBOOK.md step 0"
  ok "enabled and started"
fi

# ------------------------------------------------------------- 3. NextDNS
phase "NextDNS CLI (runbook step 3)"
# On a Debian-based distro this is fully unattended: NextDNS publish an apt
# repository, so we add that and install the package. Upgrades then arrive
# through apt like anything else.
#
# Configuring it is a separate step, and the flag name matters. Older CLI
# builds take -profile, newer ones -config. A wrong flag here is the worst
# kind of failure: the service starts, nothing errors, and DNS goes out
# unfiltered. So probe --help for which one this build accepts, use it, and
# refuse to carry on if neither is there.
NEXTDNS_KEYRING=/usr/share/keyrings/nextdns.gpg
NEXTDNS_LIST=/etc/apt/sources.list.d/nextdns.list

add_nextdns_repo() {
  if [ -s "$NEXTDNS_KEYRING" ] && [ -s "$NEXTDNS_LIST" ]; then
    ok "apt repository already configured"; return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    skip "add repo.nextdns.io to apt and install the nextdns package"; return 0
  fi
  curl -fsSL https://repo.nextdns.io/nextdns.gpg -o "$NEXTDNS_KEYRING.tmp" || {
    rm -f "$NEXTDNS_KEYRING.tmp"; note "couldn't fetch the NextDNS signing key"; return 1
  }
  mv "$NEXTDNS_KEYRING.tmp" "$NEXTDNS_KEYRING"; chmod 644 "$NEXTDNS_KEYRING"
  printf 'deb [signed-by=%s] https://repo.nextdns.io/deb stable main\n' \
    "$NEXTDNS_KEYRING" > "$NEXTDNS_LIST"
  dpkg -s apt-transport-https >/dev/null 2>&1 || apt-get install -y apt-transport-https >/dev/null 2>&1
  ok "apt repository added"
}

install_nextdns_pkg() {
  add_nextdns_repo || return 1
  run apt-get update -qq || { note "apt-get update failed"; return 1; }
  run apt-get install -y nextdns || { note "couldn't install the nextdns package"; return 1; }
  ok "nextdns package installed"
}

# Prints the flag this build uses for the profile ID, or nothing if neither.
nextdns_profile_flag() {
  local helptext
  helptext=$( { nextdns install -h; nextdns install --help; nextdns -h; } 2>&1 )
  if   printf '%s' "$helptext" | grep -q -- '-config\b';  then printf -- '-config'
  elif printf '%s' "$helptext" | grep -q -- '-profile\b'; then printf -- '-profile'
  fi
}

configure_nextdns() {
  local flag
  [ -n "$PROFILE" ] || {
    note "no --profile given — run 'sudo nextdns install' by hand, or re-run with --profile ID"
    return 1
  }
  if [ "$DRY_RUN" -eq 1 ]; then
    skip "nextdns install -profile|-config $PROFILE -report-client-info -auto-activate"; return 0
  fi
  flag=$(nextdns_profile_flag)
  [ -n "$flag" ] || {
    note "this CLI build takes neither -config nor -profile — configure it by hand:"
    note "  sudo nextdns install -profile $PROFILE -report-client-info -auto-activate"
    return 1
  }
  # -report-client-info and -auto-activate are booleans, so they stand alone.
  # The CLI will warn that client discovery is off because it listens on
  # loopback only; expected here, and it doesn't affect filtering.
  nextdns install "$flag" "$PROFILE" -report-client-info -auto-activate \
    && { ok "configured with profile $PROFILE (via $flag)"; return 0; }
  note "nextdns install failed — try it by hand: sudo nextdns install"
  return 1
}

if command -v nextdns >/dev/null; then
  ok "nextdns CLI present ($(nextdns version 2>/dev/null | head -1 || echo 'version unknown'))"
else
  note "nextdns CLI not installed"
  if ! install_nextdns_pkg; then
    note "falling back to the interactive installer"
    cat <<EOF

  It will ask you three things:
    1. choose  Install
    2. Profile ID:            ${PROFILE:-<the six-character ID from my.nextdns.io>}
    3. answer  y  to reporting device info, and  y  to auto-activate

EOF
    if confirm "Run the NextDNS installer now?"; then
      if [ "$DRY_RUN" -eq 1 ]; then
        skip 'sh -c "$(curl -sL https://nextdns.io/install)"'
      else
        [ -n "${NEXTDNS_VERSION:-}" ] && note "using NEXTDNS_VERSION=$NEXTDNS_VERSION"
        sh -c "$(curl -sL https://nextdns.io/install)"
      fi
    else
      die "install the NextDNS CLI (runbook step 3), then re-run this script"
    fi
  fi
  command -v nextdns >/dev/null || [ "$DRY_RUN" -eq 1 ] \
    || die "nextdns still not on PATH — check the output above and re-run"
fi

systemctl is-enabled --quiet nextdns 2>/dev/null \
  && ok "nextdns service enabled" \
  || { note "nextdns service is not enabled"; configure_nextdns || true; }
systemctl is-active --quiet nextdns && ok "nextdns service running" \
  || note "nextdns service not running — check: systemctl status nextdns"

# --------------------------------------------------- 4. DNS / Firefox / lid
phase "DNS hardening (runbook step 5)"
if loginctl list-users --no-legend 2>/dev/null | awk '{print $2}' | grep -qx "$CHILD"; then
  note "$CHILD is logged in — their lid-close setting can't be written while they are"
  note "log them out and re-run if you want that step to take effect"
fi
run "$HERE/kid-net-setup.sh" "$CHILD" || die "kid-net-setup.sh failed — fix the [!!] lines above and re-run"

# ------------------------------------------------------- 5. app-gate + audit
phase "App gating (runbook step 6)"
run "$HERE/app-gate.sh" install "$CHILD" "$PARENT" || die "app-gate install failed"
run /usr/local/sbin/app-gate audit || die "app-gate audit failed"

# ------------------------------------------------------------------ 6. done
phase "Stopping here — your turn"
cat <<EOF

  Everything mechanical is done. What's left needs your judgement.

  1. Review the app list. Work through it in this order: UNRECOGNISED
     first, then LOCK (is anything there she actually needs?), then a
     skim of KEEP.

         sudo nano /etc/app-gate/app-gate.list

  2. Apply your decisions:

         sudo app-gate apply

  3. Log $PARENT out and back in, so the 'gatedapps' group takes effect.

  4. Reboot, so the lid-close fallback takes effect.

  5. Log in as $CHILD and work through the verification checklist in
     RUNBOOK.md step 8.

  Still to do on the web, if you haven't: set the filtering categories,
  SafeSearch, YouTube Restricted Mode and the block page at my.nextdns.io.

EOF
