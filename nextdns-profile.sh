#!/bin/bash
#
# nextdns-profile — manage a NextDNS profile as a versioned JSON file.
#
#   ./nextdns-profile.sh export [FILE]     save the live profile to FILE
#   ./nextdns-profile.sh diff   [FILE]     show live vs FILE
#   ./nextdns-profile.sh apply  [FILE]     push FILE to the live profile
#   ./nextdns-profile.sh blocked SEARCH    blocked domains matching SEARCH
#   ./nextdns-profile.sh schema            dump the raw profile, keys only
#
# Why: the filtering policy is the least reproducible part of this setup —
# forty-odd dashboard toggles applied by hand, with nothing to check them
# against. This turns it into a file you can review, diff and re-apply.
#
# NOT run on the child's laptop. An API key that can change filtering can
# also switch it off; keep it on the parent's machine.
#
set -uo pipefail

API=https://api.nextdns.io
DEFAULT_FILE=nextdns-profile.json
KEY_FILE_DEFAULT="${HOME}/.config/nextdns/api-key"
ASSUME_YES=0

die()  { echo "nextdns-profile: $*" >&2; exit 1; }
ok()   { echo "  [ok] $*"; }
note() { echo "  [!!] $*"; }

command -v curl >/dev/null || die "curl is required"
command -v jq   >/dev/null || die "jq is required (sudo apt install jq)"

# ------------------------------------------------------------------- the key
# Never taken as a command-line argument: arguments are visible to every user
# on the machine via ps.
load_key() {
  if [ -n "${NEXTDNS_API_KEY:-}" ]; then
    KEY="$NEXTDNS_API_KEY"; return
  fi
  local f="${NEXTDNS_API_KEY_FILE:-$KEY_FILE_DEFAULT}"
  [ -f "$f" ] || die "no API key. Set NEXTDNS_API_KEY, or put it in $f (chmod 600).
  Find it at the bottom of https://my.nextdns.io/account"
  local perms; perms=$(stat -c %a "$f")
  case "$perms" in
    600|400) ;;
    *) die "$f is mode $perms — readable by others. Fix with: chmod 600 $f";;
  esac
  KEY=$(tr -d '[:space:]' < "$f")
  [ -n "$KEY" ] || die "$f is empty"
}

# Resolved once at startup, not via $(...) — die inside a command substitution
# only exits the subshell, so the caller would sail on with an empty ID.
PROFILE=""
load_profile() {
  [ -n "${NEXTDNS_PROFILE:-}" ] || die "set NEXTDNS_PROFILE to the six-character profile ID"
  PROFILE="$NEXTDNS_PROFILE"
}

# api METHOD PATH [BODY] — prints the response body, dies on transport failure.
api() {
  local method="$1" path="$2" body="${3:-}" out code
  out=$(mktemp)
  if [ -n "$body" ]; then
    code=$(curl -sS -o "$out" -w '%{http_code}' -X "$method" "$API$path" \
      -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' -d "$body")
  else
    code=$(curl -sS -o "$out" -w '%{http_code}' -X "$method" "$API$path" \
      -H "X-Api-Key: $KEY")
  fi
  # The API reports user errors as 200 with an errors array, so check the body
  # as well as the status.
  if [ "$code" != "200" ] || jq -e '.errors? // empty | length > 0' "$out" >/dev/null 2>&1; then
    echo "  HTTP $code on $method $path" >&2
    jq -r '.errors[]? | "  \(.code): \(.detail) \(.source // {} | tostring)"' "$out" >&2 2>/dev/null \
      || sed 's/^/  /' "$out" >&2
    rm -f "$out"; return 1
  fi
  cat "$out"; rm -f "$out"
}

# ------------------------------------------------------------------ commands
cmd_export() {
  local file="${1:-$DEFAULT_FILE}" body
  body=$(api GET "/profiles/$PROFILE") || die "couldn't fetch the profile"
  printf '%s' "$body" | jq '.data' > "$file" || die "unexpected response shape"
  ok "wrote $file ($(jq -r '[paths]|length' "$file") fields)"
  echo
  echo "  Commit it. It's configuration, not secrets — the API key isn't in it."
}

cmd_schema() {
  local body
  body=$(api GET "/profiles/$PROFILE") || die "couldn't fetch the profile"
  echo "Keys present on the live profile:"
  printf '%s' "$body" | jq -r '.data | [paths(scalars)] | map(join(".")) | unique[]' | sed 's/^/  /'
  echo
  echo "Anything here that the published docs don't mention — a recreation-time"
  echo "or schedule field, for instance — is real and settable; the docs are"
  echo "abridged. This is the authoritative shape."
}

cmd_diff() {
  local file="${1:-$DEFAULT_FILE}" body tmp
  [ -f "$file" ] || die "$file not found — run export first"
  body=$(api GET "/profiles/$PROFILE") || die "couldn't fetch the profile"
  tmp=$(mktemp); printf '%s' "$body" | jq -S '.data' > "$tmp"
  if diff -u <(jq -S . "$file") "$tmp" > /tmp/nextdns-diff.$$ 2>&1; then
    ok "live profile matches $file"
    rm -f "$tmp" /tmp/nextdns-diff.$$; return 0
  fi
  echo "Differences (- live, + $file):"
  sed 's/^/  /' /tmp/nextdns-diff.$$
  rm -f "$tmp" /tmp/nextdns-diff.$$
  return 1
}

# Objects take PATCH; arrays take PUT. A single PATCH of the whole document
# would not reliably replace the arrays, so each is pushed to its own endpoint.
OBJECT_PATHS=(security privacy parentalControl settings)
ARRAY_PATHS=(security/tlds privacy/blocklists privacy/natives
             parentalControl/services parentalControl/categories
             denylist allowlist)

cmd_apply() {
  local file="${1:-$DEFAULT_FILE}" p sub body rc=0
  [ -f "$file" ] || die "$file not found — run export first"
  jq -e . "$file" >/dev/null || die "$file is not valid JSON"

  if [ "$ASSUME_YES" -eq 0 ]; then
    echo "Dry run. This would push $file to profile $PROFILE:"
    echo
    cmd_diff "$file"
    echo
    echo "  Re-run with --yes to apply."
    return 0
  fi

  for p in "${OBJECT_PATHS[@]}"; do
    # Strip the nested arrays; they go to their own endpoints below.
    body=$(jq -c --arg k "$p" '
      .[$k] // empty
      | del(.tlds?, .blocklists?, .natives?, .services?, .categories?)' "$file")
    [ -n "$body" ] && [ "$body" != "null" ] || { note "no $p in $file — skipped"; continue; }
    api PATCH "/profiles/$PROFILE/$p" "$body" >/dev/null \
      && ok "PATCH $p" || { note "PATCH $p failed"; rc=1; }
  done

  for p in "${ARRAY_PATHS[@]}"; do
    sub=$(printf '%s' "$p" | tr '/' '.')
    body=$(jq -c "getpath(\"$sub\" | split(\".\")) // empty" "$file")
    [ -n "$body" ] && [ "$body" != "null" ] || { note "no $p in $file — skipped"; continue; }
    api PUT "/profiles/$PROFILE/$p" "$body" >/dev/null \
      && ok "PUT $p" || { note "PUT $p failed"; rc=1; }
  done

  echo
  [ "$rc" -eq 0 ] && ok "applied — run 'diff' to confirm" \
                  || note "some sections failed; the profile is part-applied. Run 'diff'."
  return "$rc"
}

# The iPlayer problem: find what's actually being blocked, rather than guessing
# a service's domains.
cmd_blocked() {
  local search="${1:-}" body
  [ -n "$search" ] || die "usage: $0 blocked SEARCH   (e.g. bbc)"
  body=$(api GET "/profiles/$PROFILE/logs?status=blocked&search=$search&limit=1000") \
    || die "couldn't fetch logs (are logs enabled on this profile?)"
  echo "Blocked lookups matching '$search':"
  printf '%s' "$body" | jq -r '
    .data
    | group_by(.domain)
    | map({domain: .[0].domain, n: length,
           why: ([.[0].reasons[]?.name] | join(", "))})
    | sort_by(-.n)[]
    | "  \(.n | tostring | (" " * (6 - length)) + .)  \(.domain)   [\(.why)]"'
  echo
  echo "  Allow these as FULL HOSTNAMES, not apex domains. Allowing a shared CDN"
  echo "  apex (akamaized.net, llnwd.net, cloudfront.net) opens every tenant on it,"
  echo "  and an allowlist entry outranks the Security tab."
}

# ---------------------------------------------------------------------- main
usage() { sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

cmd="${1:-}"; shift || true
for a in "$@"; do [ "$a" = "--yes" ] && ASSUME_YES=1; done
set -- "${@/--yes/}"

case "$cmd" in
  export)  load_key; load_profile; cmd_export  "${1:-}";;
  schema)  load_key; load_profile; cmd_schema;;
  diff)    load_key; load_profile; cmd_diff    "${1:-}";;
  apply)   load_key; load_profile; cmd_apply   "${1:-}";;
  blocked) load_key; load_profile; cmd_blocked "${1:-}";;
  ""|-h|--help) usage;;
  *) die "unknown command: $cmd (try --help)";;
esac
