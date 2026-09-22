#!/usr/bin/env bash
#
# Station 4 - confirmation (inside), run by the security reviewer after the merge.
#
# Compares GitLab main against the head the exporter declared, records the
# airlock/seq/<n> tag that is the durable ledger entry, and writes the receipt
# that becomes the base for the next export.
#
# Be precise about what the comparison proves: from inside the network GitHub is
# unreachable, so the manifest value is the only one available and it travelled
# with the bundle. It proves that what merged is what the exporter said it was
# exporting. The demo adds the human half by showing GitHub's main SHA on screen
# beside it.
#
#   airlock-confirm.sh 2
#
source "$(dirname "${BASH_SOURCE[0]}")/airlock-lib.sh"

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRANSFER="${AIRLOCK_TRANSFER:-$LAB_ROOT/transfer}"
PUSHREPO="$LAB_ROOT/importer/push.git"
GITLAB_URL="${GITLAB_URL:-http://127.0.0.1:8929}"
GITLAB_PROJECT="${GITLAB_PROJECT:-airlock/adabas-to-oracle-migration}"
BRANCH=main

SEQ="${1:-}"
[[ -n "$SEQ" ]] || die "usage: airlock-confirm.sh <seq>"
require_clean_seq "$SEQ"

GL_USER="${REVIEWER_USER:-}"; GL_TOKEN="${REVIEWER_TOKEN:-}"
[[ -n "$GL_USER" && -n "$GL_TOKEN" ]] || die "set REVIEWER_USER and REVIEWER_TOKEN - the tag is the reviewer's act, not the importer's"
REMOTE="http://$GL_USER:$GL_TOKEN@${GITLAB_URL#http://}/$GITLAB_PROJECT.git"

PAD="$(seqpad "$SEQ")"
IN="$TRANSFER/seq-$PAD"
MANIFEST="$IN/manifest.json"
VERDICT="$IN/verdict.json"
[[ -f "$MANIFEST" ]] || die "no manifest at $MANIFEST"

step "Station 4 - confirm - seq $SEQ"

CHECK="$LAB_ROOT/importer/confirm.git"
rm -rf "$CHECK"
git init --quiet --bare "$CHECK"
git -C "$CHECK" remote add origin "$REMOTE"
git -C "$CHECK" fetch --quiet origin "+refs/heads/$BRANCH:refs/heads/$BRANCH" "+refs/tags/*:refs/tags/*"

GITLAB_HEAD="$(git -C "$CHECK" rev-parse --verify "refs/heads/$BRANCH")"
EXPECTED="$(jget "$MANIFEST" .head_sha)"

log ""
printf '  github  %s  %s\n' "$BRANCH" "$EXPECTED"     >&2
printf '  gitlab  %s  %s\n' "$BRANCH" "$GITLAB_HEAD"  >&2
log ""

if [[ "$GITLAB_HEAD" != "$EXPECTED" ]]; then
  die "GitLab $BRANCH is $GITLAB_HEAD, the manifest declared $EXPECTED - the merge request has not been merged, or it was not merged fast-forward"
fi
ok "identical SHA - git is content addressed, so the two histories are identical byte for byte"

# The ledger entry. It survives a quarantine rebuild, which is why station 2 can
# refuse a replay even after the mirror is thrown away and re-cloned. In
# production a GitLab webhook can create it instead of a person.
TAG="airlock/seq/$SEQ"
if git -C "$CHECK" rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
  ok "$TAG already recorded"
else
  git -C "$CHECK" tag "$TAG" "$GITLAB_HEAD"
  git -C "$CHECK" push --quiet origin "refs/tags/$TAG"
  ok "recorded $TAG in GitLab"
fi

cat > "$IN/receipt.json" <<JSON
{
  "schema": "airlock/receipt/1",
  "seq": $SEQ,
  "accepted_sha": "$GITLAB_HEAD",
  "ledger_tag": "$TAG",
  "verdict_bundle_sha256": "$(jget "$VERDICT" .bundle_sha256)",
  "confirmed_by": "$GL_USER (provenance label, not an attestation)",
  "confirmed_at": "$(now_iso)",
  "script_version": "$AIRLOCK_SCRIPT_VERSION",
  "next_export_base": "$GITLAB_HEAD"
}
JSON

mkdir -p "$TRANSFER/state"
cp "$IN/receipt.json" "$TRANSFER/state/last-accepted.json"

ok "receipt written: $IN/receipt.json"
log ""
log "Next export:"
log "  scripts/airlock-export.sh --seq $((SEQ + 1)) --base $GITLAB_HEAD"
