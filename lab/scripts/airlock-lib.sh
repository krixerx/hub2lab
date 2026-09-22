# Shared helpers for the airlock stations. Sourced, not executed.
# shellcheck shell=bash

set -o errexit -o nounset -o pipefail

AIRLOCK_SCRIPT_VERSION="${AIRLOCK_SCRIPT_VERSION:-1.0.0}"

_c_red=$'\033[31m'; _c_grn=$'\033[32m'; _c_yel=$'\033[33m'; _c_dim=$'\033[2m'; _c_off=$'\033[0m'

log()  { printf '%s\n' "$*" >&2; }
step() { printf '\n%s== %s ==%s\n' "$_c_dim" "$*" "$_c_off" >&2; }
ok()   { printf '%s  OK  %s %s\n' "$_c_grn" "$_c_off" "$*" >&2; }
warn() { printf '%s FLAG %s %s\n' "$_c_yel" "$_c_off" "$*" >&2; }
bad()  { printf '%s FAIL %s %s\n' "$_c_red" "$_c_off" "$*" >&2; }
die()  { bad "$*"; exit 1; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Zero-padded sequence, so seq-0002 sorts and reads consistently everywhere.
seqpad() { printf '%04d' "$1"; }

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

# Read a value out of JSON we produced ourselves.
# In the station container jq is present; on the Windows host we use Python.
jget() {
  local file="$1" path="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r "$path" < "$file"
  elif command -v python >/dev/null 2>&1; then
    python -c '
import json,sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
for part in sys.argv[2].lstrip(".").split("."):
    if part == "":
        continue
    doc = doc[int(part)] if part.isdigit() else doc[part]
print("null" if doc is None else (json.dumps(doc) if isinstance(doc,(dict,list)) else doc))
' "$file" "$path"
  else
    die "need jq or python to read $file"
  fi
}

# Every scanner and every git plumbing call that touches incoming code runs with
# a scrubbed environment, so GITLEAKS_CONFIG, GITLEAKS_CONFIG_TOML, GIT_* and
# anything else inherited cannot redirect a tool's configuration.
clean_env() {
  env -i \
    PATH=/usr/local/bin:/usr/bin:/bin \
    HOME=/tmp \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 PYTHONUTF8=1 \
    TRIVY_CACHE_DIR="${TRIVY_CACHE_DIR:-/opt/airlock/trivy-cache}" \
    "$@"
}

# Prerequisites recorded in a bundle's own header, which is the only trustworthy
# statement of what it continues from. The manifest is no more trustworthy than
# the digest that travelled beside it.
bundle_prereqs() {
  local bundle="$1"
  LC_ALL=C head -c 131072 "$bundle" \
    | LC_ALL=C awk '
        NR==1 { next }                      # "# v2 git bundle" / "# v3 git bundle"
        /^$/  { exit }                      # header ends at the first blank line
        /^@/  { next }                      # v3 capability lines
        /^-/  { print substr($1, 2) }       # -<sha> <comment>  = prerequisite
      '
}

require_clean_seq() { [[ "$1" =~ ^[0-9]+$ ]] || die "sequence must be a positive integer, got '$1'"; }

# JSON array from shell arguments, for verdict fields built out of shell arrays.
json_array_of() {
  if (($#)); then printf '%s\n' "$@" | jq -R . | jq -s .; else printf '[]\n'; fi
}
