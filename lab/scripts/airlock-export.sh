#!/usr/bin/env bash
#
# Station 1 — developer zone (outside).
#
# Exports everything on main since the last accepted commit as one incremental
# git bundle, with a manifest and a SHA-256. Runs on the developer PC under
# Git for Windows bash. Touches nothing inside the customer network.
#
#   airlock-export.sh --seq 2 --base <last accepted sha>
#   airlock-export.sh --seq 1 --base none          # baseline, no predecessor
#
source "$(dirname "${BASH_SOURCE[0]}")/airlock-lib.sh"

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_URL="${AIRLOCK_SOURCE_URL:-https://github.com/krixerx/adabas-to-oracle-migration}"
MIRROR="${AIRLOCK_EXPORT_MIRROR:-$LAB_ROOT/exporter/github.git}"
OUT_ROOT="${AIRLOCK_TRANSFER:-$LAB_ROOT/transfer}"
BRANCH=main
SEQ=""; BASE=""; TAGS=()

while (($#)); do
  case "$1" in
    --seq)    SEQ="$2"; shift 2 ;;
    --base)   BASE="$2"; shift 2 ;;
    --tag)    TAGS+=("$2"); shift 2 ;;
    --source) SOURCE_URL="$2"; shift 2 ;;
    --out)    OUT_ROOT="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$SEQ"  ]] || die "--seq is required"
[[ -n "$BASE" ]] || die "--base is required (a commit SHA, or 'none' for the baseline)"
require_clean_seq "$SEQ"

PAD="$(seqpad "$SEQ")"
OUT="$OUT_ROOT/seq-$PAD"
BUNDLE_NAME="airlock-$PAD.bundle"

step "Station 1 · export · seq $SEQ"

# ---------------------------------------------------------------------------
# Refresh the exporter's own mirror of GitHub. A bare mirror, not the developer's
# working clone, so the bundle carries refs/heads/main rather than a remote ref
# and nobody's working tree is disturbed mid-export.
# ---------------------------------------------------------------------------
if [[ ! -d "$MIRROR" ]]; then
  log "cloning $SOURCE_URL into $MIRROR"
  mkdir -p "$(dirname "$MIRROR")"
  git clone --quiet --bare "$SOURCE_URL" "$MIRROR"
fi
# Set on every run, not only on the clone. A mirror left over from an earlier
# source would otherwise keep fetching the old repository while the manifest
# names the new one, and nothing in the output would say so.
git -C "$MIRROR" config remote.origin.url "$SOURCE_URL"
git -C "$MIRROR" config remote.origin.fetch '+refs/heads/*:refs/heads/*'
git -C "$MIRROR" fetch --quiet --prune --force origin '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'

HEAD_SHA="$(git -C "$MIRROR" rev-parse --verify "refs/heads/$BRANCH")"
ok "GitHub $BRANCH is $HEAD_SHA"

# ---------------------------------------------------------------------------
# The ancestor assertion. If the last accepted commit is no longer reachable from
# GitHub main, someone rewrote history the security team has already approved.
# The fast-forward inside is now impossible. Do not produce a bundle; this is a
# policy event and the re-baseline procedure applies.
# ---------------------------------------------------------------------------
RANGE_ARGS=()
if [[ "$BASE" == "none" ]]; then
  [[ "$SEQ" == "1" ]] || warn "baseline export (--base none) with seq $SEQ, not 1"
  BASE_JSON=null
  RANGE_ARGS=("$BRANCH")
  COMMITS="$(git -C "$MIRROR" rev-list --reverse "$BRANCH")"
else
  git -C "$MIRROR" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null \
    || die "base $BASE is not a commit in $SOURCE_URL"
  BASE="$(git -C "$MIRROR" rev-parse --verify "$BASE^{commit}")"
  git -C "$MIRROR" merge-base --is-ancestor "$BASE" "$BRANCH" \
    || die "base $BASE is NOT an ancestor of GitHub $BRANCH — accepted history was rewritten. Stop. Do not export. Apply the re-baseline procedure."
  [[ "$BASE" != "$HEAD_SHA" ]] || die "nothing to export: GitHub $BRANCH is still at the last accepted commit"
  BASE_JSON="\"$BASE\""
  RANGE_ARGS=("$BRANCH" "^$BASE")
  COMMITS="$(git -C "$MIRROR" rev-list --reverse "$BASE..$BRANCH")"
  ok "base $BASE is still an ancestor of $BRANCH"
fi

# Tags travel only when named here. Feature branches never travel: station 3 merges
# only main, so any other branch would land inside having been read by nobody.
REFS_JSON="\"refs/heads/$BRANCH\": \"$HEAD_SHA\""
for t in ${TAGS+"${TAGS[@]}"}; do
  tsha="$(git -C "$MIRROR" rev-parse --verify "refs/tags/$t")" || die "no such tag: $t"
  RANGE_ARGS+=("refs/tags/$t")
  REFS_JSON="$REFS_JSON,
    \"refs/tags/$t\": \"$tsha\""
done

rm -rf "$OUT"; mkdir -p "$OUT"
git -C "$MIRROR" bundle create "$OUT/$BUNDLE_NAME" "${RANGE_ARGS[@]}" 2>&1 | sed 's/^/    /' >&2

BUNDLE_SHA="$(sha256_of "$OUT/$BUNDLE_NAME")"
BUNDLE_BYTES="$(wc -c < "$OUT/$BUNDLE_NAME" | tr -d ' ')"
printf '%s  %s\n' "$BUNDLE_SHA" "$BUNDLE_NAME" > "$OUT/$BUNDLE_NAME.sha256"

COMMIT_COUNT="$(printf '%s' "$COMMITS" | grep -c . || true)"
COMMITS_JSON="$(printf '%s\n' "$COMMITS" | grep . | sed 's/.*/    "&",/' | sed '$ s/,$//')"

cat > "$OUT/manifest.json" <<JSON
{
  "schema": "airlock/manifest/1",
  "seq": $SEQ,
  "source_repo": "$SOURCE_URL",
  "source_branch": "$BRANCH",
  "base": $BASE_JSON,
  "head_sha": "$HEAD_SHA",
  "commit_count": $COMMIT_COUNT,
  "commits": [
$COMMITS_JSON
  ],
  "refs": {
    $REFS_JSON
  },
  "bundle_file": "$BUNDLE_NAME",
  "bundle_sha256": "$BUNDLE_SHA",
  "bundle_bytes": $BUNDLE_BYTES,
  "exporter": "${AIRLOCK_EXPORTER:-$(git config user.name || echo unknown)} (provenance label, not an attestation)",
  "exported_at": "$(now_iso)",
  "script_version": "$AIRLOCK_SCRIPT_VERSION"
}
JSON

ok "$COMMIT_COUNT commit(s), $BUNDLE_BYTES bytes"
ok "sha256 $BUNDLE_SHA"
log ""
log "Ready to carry across: $OUT"
ls -l "$OUT" | sed 's/^/    /' >&2
