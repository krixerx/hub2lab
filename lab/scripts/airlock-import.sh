#!/usr/bin/env bash
#
# Station 3 - import into GitLab (inside).
#
# Run on the host, NOT in the station container. The station that executes
# scanners over untrusted incoming code holds no GitLab write credentials; this
# step does, and it is a separate action by a named person.
#
#   airlock-import.sh 1 --baseline       # reviewer pushes the baseline to main
#   airlock-import.sh 2                  # importer pushes incoming/2 + opens an MR
#   airlock-import.sh 2 --direct-to-main  # the bypass attempt, for the demo
#
source "$(dirname "${BASH_SOURCE[0]}")/airlock-lib.sh"

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRANSFER="${AIRLOCK_TRANSFER:-$LAB_ROOT/transfer}"
PUSHREPO="$LAB_ROOT/importer/push.git"
GITLAB_URL="${GITLAB_URL:-http://127.0.0.1:8929}"
GITLAB_PROJECT="${GITLAB_PROJECT:-airlock/adabas-to-oracle-migration}"
BRANCH=main
MODE=incremental

SEQ="${1:-}"
[[ -n "$SEQ" ]] || die "usage: airlock-import.sh <seq> [--baseline|--direct-to-main]"
shift
require_clean_seq "$SEQ"
while (($#)); do
  case "$1" in
    --baseline)       MODE=baseline; shift ;;
    --direct-to-main) MODE=bypass; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

PAD="$(seqpad "$SEQ")"
IN="$TRANSFER/seq-$PAD"
MANIFEST="$IN/manifest.json"
VERDICT="$IN/verdict.json"
[[ -f "$MANIFEST" ]] || die "no manifest at $MANIFEST"
[[ -f "$VERDICT"  ]] || die "no verdict at $VERDICT - the security station has not decided on this bundle"
BUNDLE="$IN/$(jget "$MANIFEST" .bundle_file)"

# The reviewer pushes the baseline (Maintainer). Everything after that is the
# importer (Developer), who cannot merge.
if [[ "$MODE" == baseline ]]; then
  ACTOR=reviewer; USER_VAR=REVIEWER_USER; TOKEN_VAR=REVIEWER_TOKEN
else
  ACTOR=importer; USER_VAR=IMPORTER_USER; TOKEN_VAR=IMPORTER_TOKEN
fi
GL_USER="${!USER_VAR:-}"; GL_TOKEN="${!TOKEN_VAR:-}"
[[ -n "$GL_USER" && -n "$GL_TOKEN" ]] || die "set $USER_VAR and $TOKEN_VAR (see lab/.secrets written by gitlab-bootstrap.sh)"
REMOTE="http://$GL_USER:$GL_TOKEN@${GITLAB_URL#http://}/$GITLAB_PROJECT.git"

step "Station 3 - import - seq $SEQ (as $ACTOR)"

# ---------------------------------------------------------------------------
# The gate's decision, re-checked against the bytes that are here now. This is
# what catches a bundle swapped after it was scanned: the verdict names a digest,
# and the digest is recomputed rather than trusted.
# ---------------------------------------------------------------------------
RESULT="$(jget "$VERDICT" .verdict)"
[[ "$RESULT" == PASS ]] || die "verdict for seq $SEQ is $RESULT - nothing is pushed"
VERDICT_SHA="$(jget "$VERDICT" .bundle_sha256)"
NOW_SHA="$(sha256_of "$BUNDLE")"
[[ "$VERDICT_SHA" == "$NOW_SHA" ]] \
  || die "the bundle here is not the bundle that was scanned (verdict $VERDICT_SHA, file $NOW_SHA)"
ok "verdict PASS, and it refers to exactly these bytes"

HEAD_SHA="$(jget "$MANIFEST" .head_sha)"

# ---------------------------------------------------------------------------
# A local bare repo the importer pushes from. The bundle is unpacked here with
# fsck on; nothing unpacks inside GitLab.
# ---------------------------------------------------------------------------
[[ -d "$PUSHREPO" ]] || { mkdir -p "$(dirname "$PUSHREPO")"; git init --quiet --bare "$PUSHREPO"; }
git -C "$PUSHREPO" remote remove origin 2>/dev/null || true
git -C "$PUSHREPO" remote add origin "$REMOTE"
git -C "$PUSHREPO" fetch --quiet --prune --force origin "+refs/heads/*:refs/heads/*" 2>/dev/null || true
git -c fetch.fsckObjects=true -C "$PUSHREPO" fetch --quiet "$BUNDLE" "refs/heads/$BRANCH:refs/heads/airlock-incoming"
UNPACKED="$(git -C "$PUSHREPO" rev-parse refs/heads/airlock-incoming)"
[[ "$UNPACKED" == "$HEAD_SHA" ]] || die "unpacked head $UNPACKED does not match the manifest"
ok "unpacked locally at $HEAD_SHA"

case "$MODE" in
  baseline)
    # No merge request in the baseline: an empty project has no main, so there is
    # nothing to open one into. Protection is applied immediately afterwards,
    # which makes this a visible one-time bootstrap rather than a hole.
    git -C "$PUSHREPO" push origin "refs/heads/airlock-incoming:refs/heads/$BRANCH"
    ok "baseline pushed to $BRANCH - now apply branch protection before anything else"
    ;;
  bypass)
    # Stage 4 of the demo. Expected to be refused by GitLab.
    log "attempting a direct push to protected $BRANCH as $ACTOR - this is expected to fail"
    if git -C "$PUSHREPO" push origin "refs/heads/airlock-incoming:refs/heads/$BRANCH"; then
      die "GitLab ACCEPTED a direct push to $BRANCH - branch protection is not configured correctly"
    fi
    ok "GitLab refused the direct push to $BRANCH, as it should"
    ;;
  incremental)
    # Merge request push options are Community Edition, so the branch and the
    # merge request are one command. Push options must be single-line, so the
    # reviewer's summary is attached afterwards.
    git -C "$PUSHREPO" push \
      -o merge_request.create \
      -o merge_request.target="$BRANCH" \
      -o merge_request.title="Airlock seq $SEQ - $(jget "$MANIFEST" .commit_count) commit(s) from GitHub main" \
      origin "refs/heads/airlock-incoming:refs/heads/incoming/$SEQ"
    ok "pushed incoming/$SEQ and opened a merge request into $BRANCH"

    DESCRIPTION="$(cat <<DESC
**This branch was carried in as a git bundle and cleared by the security station.**

| | |
|---|---|
| Bundle | \`$(jget "$MANIFEST" .bundle_file)\` |
| Bundle sha256 | \`$NOW_SHA\` |
| Base (your current main) | \`$(jget "$MANIFEST" .base)\` |
| Head | \`$HEAD_SHA\` |
| Commits | $(jget "$MANIFEST" .commit_count) |
| Verdict | **PASS**, $(jget "$VERDICT" .decided_at) |
| Scanners | $(jget "$VERDICT" .scanners.gitleaks) / opengrep $(jget "$VERDICT" .scanners.opengrep) / trivy $(jget "$VERDICT" .scanners.trivy.version) |

Merge **fast-forward only**. Afterwards, record the ledger tag with
\`scripts/airlock-confirm.sh $SEQ\`.
DESC
)"
    MR_IID="$(curl -sS -H "PRIVATE-TOKEN: $GL_TOKEN" \
      "$GITLAB_URL/api/v4/projects/$(printf '%s' "$GITLAB_PROJECT" | sed 's|/|%2F|')/merge_requests?source_branch=incoming/$SEQ&state=opened" \
      | python -c 'import json,sys; m=json.load(sys.stdin); print(m[0]["iid"] if m else "")')"
    if [[ -n "$MR_IID" ]]; then
      curl -sS -X PUT -H "PRIVATE-TOKEN: $GL_TOKEN" \
        "$GITLAB_URL/api/v4/projects/$(printf '%s' "$GITLAB_PROJECT" | sed 's|/|%2F|')/merge_requests/$MR_IID" \
        --data-urlencode "description=$DESCRIPTION" >/dev/null
      ok "merge request !$MR_IID carries the bundle digest and the verdict"
    else
      warn "could not find the new merge request to attach the summary to"
    fi
    log ""
    log "$BRANCH is unchanged until a Maintainer merges it."
    log "Open: $GITLAB_URL/$GITLAB_PROJECT/-/merge_requests"
    ;;
esac
