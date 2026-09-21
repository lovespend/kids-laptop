#!/bin/bash
#
# app-gate — hide and block desktop apps for a child's account (Linux Mint / Cinnamon)
#
#   sudo ./app-gate.sh install CHILD PARENT   one-off: installs to /usr/local/sbin/app-gate
#   sudo app-gate audit                       build/refresh the review list
#   sudo app-gate apply                       enforce the list
#   sudo app-gate status                      show what's locked, flag drift
#   sudo app-gate revert                      unlock everything (keeps the list)
#   sudo app-gate uninstall                   revert + remove all traces
#
# How it works: LOCKed apps are hidden from the child's menu (a NoDisplay=true
# override in the child's ~/.local/share/applications) AND their binary is set
# to root:gatedapps 750, so only root and members of 'gatedapps' (the parent)
# can run them — whichever way they're launched.
#
set -uo pipefail

CONF_DIR=/etc/app-gate
CONF="$CONF_DIR/app-gate.conf"
LIST="$CONF_DIR/app-gate.list"
INSTALL_PATH=/usr/local/sbin/app-gate
APT_HOOK=/etc/apt/apt.conf.d/99app-gate
GROUP=gatedapps
QUIET=0

DESKTOP_DIRS=(
  /usr/share/applications
  /usr/local/share/applications
  /var/lib/flatpak/exports/share/applications
  /var/lib/snapd/desktop/applications
)

# Never touched, whatever the list says. Locking these breaks the desktop or
# the system for everyone (shells, interpreters, launch wrappers, session).
PROTECTED_RE='^(sh|bash|dash|zsh|env|sudo|pkexec|su|python[0-9.]*|perl|ruby|java|mono|node|flatpak|snap|xdg-open|gio|dbus-launch|cinnamon|cinnamon-session.*|cinnamon-screensaver.*|cinnamon-menu-editor|nemo-desktop|nm-applet|systemctl|loginctl)$'

log()  { [ "$QUIET" -eq 1 ] || echo "$@"; }
warn() { echo "app-gate: WARNING: $*" >&2; }
die()  { echo "app-gate: $*" >&2; exit 1; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

load_conf() {
  [ -f "$CONF" ] || die "not installed — run: sudo ./app-gate.sh install CHILD PARENT"
  # shellcheck disable=SC1090
  . "$CONF"
  id "$CHILD_USER" >/dev/null 2>&1 || die "child user '$CHILD_USER' no longer exists"
  CHILD_HOME=$(getent passwd "$CHILD_USER" | cut -d: -f6)
  APPDIR="$CHILD_HOME/.local/share/applications"
}

# Read list lines: VERDICT | id | bin  # Name   -> "VERDICT<TAB>id<TAB>bin"
read_list() {
  grep -v '^[[:space:]]*#' "$LIST" | grep '|' | while IFS='|' read -r v id bin; do
    v=$(trim "$v"); id=$(trim "$id"); bin=$(trim "${bin%%#*}")
    [ -n "$v" ] && [ -n "$id" ] && printf '%s\t%s\t%s\n' "$v" "$id" "$bin"
  done
}

is_locked() { [ -e "$1" ] && [ "$(stat -L -c %G "$1" 2>/dev/null)" = "$GROUP" ]; }

# ----------------------------------------------------------------- classifier
# Defaults tuned for an ~11-year-old on Mint/Cinnamon. Edit to taste.
#   LOCK = admin/system surface, shells, dev & remote-access tools, and anything
#          that routes around DNS filtering (other browsers, VPN, torrents).
#   KEEP = daily essentials, schoolwork, creative, media, games.
#   ASK  = unrecognised -> treated as KEEP until you decide.
classify() {
  local id="$1" cats="$2" name="$3" hay
  hay=$(printf '%s %s %s' "$id" "$cats" "$name" | tr '[:upper:]' '[:lower:]')

  case "$hay" in
    *gnome-disks*|*gparted*|*disk-utility*|*baobab*|*usb-creator*|*mintstick*) echo LOCK; return;;
    *synaptic*|*software-properties*|*update-manager*|*mintupdate*|*mintsources*|\
    *mintdrivers*|*mintbackup*|*mintinstall*|*gnome-software*|*packagekit*|*gdebi*) echo LOCK; return;;
    *users-admin*|*user-accounts*|*gufw*|*firewall*|*timeshift*|*grub*|*boot-repair*) echo LOCK; return;;
    *lightdm-settings*|*login*window*|*system-reports*|*mintreport*) echo LOCK; return;;
    *terminal*|*konsole*|*xterm*|*tilix*|*guake*|*yakuake*|*terminator*) echo LOCK; return;;
    *virtualbox*|*virt-manager*|*vmware*|*qemu*|*gnome-boxes*|*wine*|*bottles*) echo LOCK; return;;
    *remmina*|*vinagre*|*teamviewer*|*anydesk*|*rustdesk*|*putty*|*filezilla*) echo LOCK; return;;
    *tor-browser*|*torbrowser*|*brave*|*opera*|*vivaldi*|*chromium*|*google-chrome*|\
    *microsoft-edge*|*epiphany*|*midori*|*falkon*|*konqueror*|*librewolf*|*waterfox*) echo LOCK; return;;
    *vpn*|*wireguard*|*tailscale*|*zerotier*|*proton*) echo LOCK; return;;
    *transmission*|*qbittorrent*|*deluge*|*torrent*|*amule*|*warpinator*) echo LOCK; return;;
  esac
  case "$cats" in
    *Development*|*IDE*|*TerminalEmulator*) echo LOCK; return;;
  esac

  case "$hay" in
    *firefox*) echo KEEP; return;;
    *nemo*|*nautilus*|*thunar*|*caja*|*dolphin*) echo KEEP; return;;
    *xed*|*gedit*|*text-editor*|*mousepad*) echo KEEP; return;;
    *cinnamon-settings*|*gnome-control-center*) echo KEEP; return;;
    *blueman*|*bluetooth*|*pavucontrol*|*sound*|*volume*) echo KEEP; return;;
    *onboard*|*orca*|*magnifier*|*accessibility*) echo KEEP; return;;
    *calculator*|*calendar*|*clocks*|*weather*|*screenshot*|*file-roller*|*archive*) echo KEEP; return;;
    *libreoffice*|*onlyoffice*|*gimp*|*inkscape*|*krita*|*pinta*|*drawing*|*tuxpaint*) echo KEEP; return;;
    *vlc*|*celluloid*|*mpv*|*totem*|*rhythmbox*|*hypnotix*|*xviewer*|*xreader*|*pix*|*evince*) echo KEEP; return;;
    *scratch*|*thonny*|*geogebra*|*stellarium*|*gcompris*|*minecraft*|*supertux*) echo KEEP; return;;
  esac
  case "$cats" in
    *Education*|*Game*|*Graphics*|*Office*|*AudioVideo*) echo KEEP; return;;
  esac

  echo ASK
}

# -------------------------------------------------------------- binary resolve
# Prints the real executable, or "-" if it can't be pinned down safely
# (e.g. Exec=sh -c "...", or a python script) — those get menu-hiding only.
resolve_bin() {
  local file="$1" id="$2" execline tok cmd="" bin
  case "$file" in
    */flatpak/exports/*) echo "/var/lib/flatpak/exports/bin/$id"; return;;
    */snapd/desktop/*)   echo "/snap/bin/${id%%_*}"; return;;
  esac
  execline=$(grep -m1 '^Exec=' "$file" 2>/dev/null | cut -d= -f2- | sed 's/%[a-zA-Z]//g; s/"//g')
  for tok in $execline; do
    case "$tok" in
      env|pkexec|*=*|-*) continue;;
      *) cmd="$tok"; break;;
    esac
  done
  [ -z "$cmd" ] && { echo "-"; return; }
  bin=$(command -v "$cmd" 2>/dev/null) || bin="$cmd"
  [[ "$(basename "$bin")" =~ $PROTECTED_RE ]] && { echo "-"; return; }
  [ -f "$bin" ] && echo "$bin" || echo "-"
}

# -------------------------------------------------------------------- install
do_install() {
  local child="${1:-}" parent="${2:-}" self
  [ -n "$child" ] && [ -n "$parent" ] || die "usage: sudo $0 install CHILD PARENT"
  id "$child"  >/dev/null 2>&1 || die "no such user: $child"
  id "$parent" >/dev/null 2>&1 || die "no such user: $parent"
  [ "$child" != "$parent" ] || die "child and parent must be different accounts"
  id -nG "$child" | grep -qwE 'sudo|admin|wheel' && \
    warn "$child has admin rights and can undo all of this. Fix: sudo deluser $child sudo"

  install -d -m 700 "$CONF_DIR"
  printf 'CHILD_USER=%q\nPARENT_USER=%q\n' "$child" "$parent" > "$CONF"
  chmod 600 "$CONF"

  self=$(readlink -f "$0")
  [ "$self" = "$INSTALL_PATH" ] || install -m 755 "$self" "$INSTALL_PATH"

  getent group "$GROUP" >/dev/null || groupadd "$GROUP"
  usermod -aG "$GROUP" "$parent"

  cat > "$APT_HOOK" <<EOF
// app-gate: package upgrades reset binary permissions; re-apply locks afterwards.
DPkg::Post-Invoke { "if [ -x $INSTALL_PATH ] && [ -f $LIST ]; then $INSTALL_PATH apply --quiet || true; fi"; };
EOF

  log "Installed: $INSTALL_PATH   config: $CONF"
  log "Child: $child   Parent: $parent (added to '$GROUP' — log out/in once)"
  log "Next: sudo app-gate audit"
}

# ---------------------------------------------------------------------- audit
# First run: classifier proposes everything. Later runs: your existing verdicts
# are kept; only newly installed apps are added, in a NEW block at the top.
do_audit() {
  load_conf
  declare -A prev=() seen=()
  local first=1 tmp v id bin dir f type name cats verdict block
  if [ -f "$LIST" ]; then
    first=0
    cp "$LIST" "$LIST.bak.$(date +%Y%m%d-%H%M%S)"
    while IFS=$'\t' read -r v id bin; do prev["$id"]="$v"; done < <(read_list)
  fi

  tmp=$(mktemp)
  for dir in "${DESKTOP_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.desktop; do
      [ -f "$f" ] || continue
      id=$(basename "$f" .desktop)
      [ -n "${seen[$id]:-}" ] && continue; seen["$id"]=1
      grep -q '^NoDisplay=true' "$f" && continue
      grep -q '^Hidden=true' "$f" && continue
      type=$(grep -m1 '^Type=' "$f" | cut -d= -f2)
      [ -n "$type" ] && [ "$type" != "Application" ] && continue

      name=$(grep -m1 '^Name=' "$f" | cut -d= -f2- | tr -d '|')
      cats=$(grep -m1 '^Categories=' "$f" | cut -d= -f2-)
      bin=$(resolve_bin "$f" "$id")

      if [ -n "${prev[$id]:-}" ]; then
        verdict="${prev[$id]}"; block="$verdict"
      else
        verdict=$(classify "$id" "$cats" "$name")
        [ "$first" -eq 1 ] && block="$verdict" || block="NEW"
      fi
      printf '%s|%s|%s|%s|%s\n' "$block" "$verdict" "$id" "$bin" "${name:-$id}" >> "$tmp"
    done
  done

  {
    echo "# app-gate list for '$CHILD_USER' — updated $(date '+%Y-%m-%d %H:%M')"
    echo "#"
    echo "# Format:  VERDICT | desktop-id | binary   # App name"
    echo "#   KEEP   visible and runnable"
    echo "#   LOCK   hidden from menu + execution blocked"
    echo "#   ASK    unrecognised — behaves as KEEP until you change it"
    echo "#   IGNORE never touched by app-gate"
    echo "# Binary '-' = couldn't be resolved safely; LOCK will only hide it from the menu."
    echo "# Edit verdicts, save, then: sudo app-gate apply"
    echo
  } > "$LIST"

  for block in NEW ASK LOCK KEEP IGNORE; do
    local n; n=$(grep -c "^$block|" "$tmp")
    [ "$n" -eq 0 ] && continue
    case $block in
      NEW)    echo "# ==== NEW since last audit ($n) — proposed verdicts, review these ====";;
      ASK)    echo "# ==== UNRECOGNISED ($n) — review these ====";;
      LOCK)   echo "# ==== LOCK ($n) ====";;
      KEEP)   echo "# ==== KEEP ($n) ====";;
      IGNORE) echo "# ==== IGNORE ($n) ====";;
    esac >> "$LIST"
    grep "^$block|" "$tmp" | sort -t'|' -k5 | \
      awk -F'|' '{printf "%-6s | %-42s | %-46s # %s\n", $2, $3, $4, $5}' >> "$LIST"
    echo >> "$LIST"
  done
  rm -f "$tmp"
  chmod 600 "$LIST"

  log "List: $LIST"
  [ "$first" -eq 1 ] && log "Review it (UNRECOGNISED first), then: sudo app-gate apply" \
                     || log "Existing verdicts kept; check the NEW block, then: sudo app-gate apply"
}

# ---------------------------------------------------------------------- apply
do_apply() {
  load_conf
  [ -f "$LIST" ] || die "no list yet — run: sudo app-gate audit"
  getent group "$GROUP" >/dev/null || groupadd "$GROUP"
  id -nG "$PARENT_USER" | grep -qw "$GROUP" || usermod -aG "$GROUP" "$PARENT_USER"

  runuser -u "$CHILD_USER" -- mkdir -p "$APPDIR"
  local v id bin dir locked=0 menuonly=0 unlocked=0 skipped=0
  # A binary shared by a KEEP and a LOCK entry (e.g. LibreOffice modules) stays
  # runnable — KEEP wins; the LOCK entry is only hidden from the menu.
  declare -A keepbin=()
  while IFS=$'\t' read -r v id bin; do
    case "$v" in KEEP|ASK) [ "$bin" != "-" ] && keepbin["$(readlink -f "$bin")"]=1;; esac
  done < <(read_list)
  while IFS=$'\t' read -r v id bin; do
    case "$v" in
      LOCK)
        for dir in "${DESKTOP_DIRS[@]}"; do
          if [ -f "$dir/$id.desktop" ]; then
            cp "$dir/$id.desktop" "$APPDIR/$id.desktop"
            sed -i '/^NoDisplay=/d' "$APPDIR/$id.desktop"
            echo "NoDisplay=true" >> "$APPDIR/$id.desktop"
            break
          fi
        done
        if [ "$bin" = "-" ] || [ ! -e "$bin" ]; then
          menuonly=$((menuonly+1))
        elif [ -n "${keepbin[$(readlink -f "$bin")]:-}" ]; then
          warn "$id shares $bin with a KEEP app — menu-hidden only"; skipped=$((skipped+1))
        elif [[ "$(basename "$(readlink -f "$bin")")" =~ $PROTECTED_RE ]]; then
          warn "refusing to lock protected binary $bin ($id) — menu-hidden only"; skipped=$((skipped+1))
        elif [ -u "$(readlink -f "$bin")" ] || [ -g "$(readlink -f "$bin")" ]; then
          warn "refusing to lock setuid/setgid $bin ($id) — menu-hidden only"; skipped=$((skipped+1))
        else
          chown root:"$GROUP" "$bin" && chmod 750 "$bin" && locked=$((locked+1))
        fi
        ;;
      KEEP|ASK)
        rm -f "$APPDIR/$id.desktop"
        if [ "$bin" != "-" ] && is_locked "$bin"; then
          chown root:root "$bin" && chmod 755 "$bin" && unlocked=$((unlocked+1))
        fi
        ;;
      IGNORE) ;;
      *) warn "unknown verdict '$v' for $id — skipped";;
    esac
  done < <(read_list)

  chown -R "$CHILD_USER": "$APPDIR"
  log "Locked $locked, menu-hidden only $menuonly, unlocked $unlocked, refused $skipped."
}

# --------------------------------------------------------------------- status
do_status() {
  load_conf
  [ -f "$LIST" ] || die "no list yet — run: sudo app-gate audit"
  local v id bin drift=0 locked=0
  declare -A keepbin=()
  while IFS=$'\t' read -r v id bin; do
    case "$v" in KEEP|ASK) [ "$bin" != "-" ] && keepbin["$(readlink -f "$bin")"]=1;; esac
  done < <(read_list)
  while IFS=$'\t' read -r v id bin; do
    [ "$v" = "LOCK" ] || continue
    [ "$bin" = "-" ] && continue
    [ -n "${keepbin[$(readlink -f "$bin")]:-}" ] && continue
    if is_locked "$bin"; then locked=$((locked+1))
    else echo "DRIFT: $id ($bin) should be locked but isn't"; drift=$((drift+1)); fi
  done < <(read_list)
  echo "Child: $CHILD_USER   Parent: $PARENT_USER   Locked binaries: $locked   Drift: $drift"
  id -nG "$PARENT_USER" | grep -qw "$GROUP" || echo "NOTE: $PARENT_USER not in $GROUP"
  [ "$drift" -gt 0 ] && echo "Fix with: sudo app-gate apply"
  return 0
}

# --------------------------------------------------------------------- revert
do_revert() {
  load_conf
  [ -f "$LIST" ] || die "no list to revert from"
  local v id bin n=0
  while IFS=$'\t' read -r v id bin; do
    rm -f "$APPDIR/$id.desktop"
    if [ "$bin" != "-" ] && is_locked "$bin"; then
      chown root:root "$bin" && chmod 755 "$bin" && n=$((n+1))
    fi
  done < <(read_list)
  log "Unlocked $n binaries and removed menu overrides. List kept at $LIST."
}

do_uninstall() {
  do_revert
  rm -f "$APT_HOOK" "$INSTALL_PATH"
  rm -rf "$CONF_DIR"
  getent group "$GROUP" >/dev/null && groupdel "$GROUP"
  log "app-gate removed."
}

# ----------------------------------------------------------------------- main
[ "$(id -u)" -eq 0 ] || die "run with sudo"
cmd="${1:-}"; shift || true
[ "${1:-}" = "--quiet" ] && QUIET=1
case "$cmd" in
  install)   do_install "$@";;
  audit)     do_audit;;
  apply)     do_apply;;
  status)    do_status;;
  revert)    do_revert;;
  uninstall) do_uninstall;;
  *) echo "Usage: sudo app-gate {install CHILD PARENT|audit|apply|status|revert|uninstall}"; exit 1;;
esac
