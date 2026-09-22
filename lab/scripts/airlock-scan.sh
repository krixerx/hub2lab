#!/usr/bin/env bash
#
# Station 2 - the security station (quarantine). Runs inside the station
# container, never on GitLab and never with GitLab write credentials.
#
# It verifies the bundle against GitLab's current state, unpacks it with object
# integrity checking and a refspec allowlist, scans it, and emits PASS or FAIL.
# Its output is a verdict, not a push.
#
#   airlock-scan.sh 2                 # refresh the mirror, then verify and scan
#   airlock-scan.sh 2 --no-refresh    # scan only; used for the offline run
#
source "$(dirname "${BASH_SOURCE[0]}")/airlock-lib.sh"

TRANSFER="${AIRLOCK_TRANSFER:-/transfer}"
QROOT="${AIRLOCK_QUARANTINE:-/quarantine}"
MIRROR="$QROOT/mirror.git"
WORK="$QROOT/work.git"
TREE="$QROOT/tree"
RULES="${AIRLOCK_RULES:-/opt/airlock/rules}"
GITLEAKS_TOML="${AIRLOCK_GITLEAKS_CONFIG:-/opt/airlock/gitleaks.toml}"
BRANCH=main
REFRESH=1
WAIVE_BASELINE_SUPPRESSIONS="${AIRLOCK_WAIVE_BASELINE_SUPPRESSIONS:-0}"

SEQ="${1:-}"
[[ -n "$SEQ" ]] || die "usage: airlock-scan.sh <seq> [--no-refresh]"
shift
require_clean_seq "$SEQ"
while (($#)); do
  case "$1" in
    --no-refresh) REFRESH=0; shift ;;
    --waive-baseline-suppressions) WAIVE_BASELINE_SUPPRESSIONS=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

PAD="$(seqpad "$SEQ")"
IN="$TRANSFER/seq-$PAD"
REPORTS="$IN/reports"
[[ -d "$IN" ]] || die "no transfer directory at $IN"
MANIFEST="$IN/manifest.json"
[[ -f "$MANIFEST" ]] || die "no manifest.json in $IN"
BUNDLE="$IN/$(jget "$MANIFEST" .bundle_file)"
[[ -f "$BUNDLE" ]] || die "manifest names a bundle that is not here: $BUNDLE"
mkdir -p "$REPORTS"

FINDINGS=()      # reasons the verdict is FAIL
FLAGS=()         # things the reviewer must look at, which do not block on their own
record_fail() { bad "$*"; FINDINGS+=("$*"); }
record_flag() { warn "$*"; FLAGS+=("$*"); }
have_findings() { [[ ${#FINDINGS[@]} -gt 0 ]]; }

emit_verdict() {
  local result="$1"
  local trivy_db_meta gl_ver og_ver tv_ver rules_sha rules_commit net
  gl_ver="$(clean_env gitleaks version 2>/dev/null | head -1)"
  og_ver="$(clean_env opengrep --version 2>/dev/null | head -1)"
  tv_ver="$(clean_env trivy --version 2>/dev/null | head -1 | awk '{print $2}')"
  trivy_db_meta="$(clean_env trivy version --format json 2>/dev/null || echo '{}')"
  rules_sha="$(cat /opt/airlock/rules.sha256 2>/dev/null || echo unknown)"
  rules_commit="$(cat /opt/airlock/rules.commit 2>/dev/null || echo unknown)"
  if [[ $REFRESH -eq 0 ]]; then
    net="mirror not refreshed; whole run was offline"
  else
    net="mirror refreshed over the LAN; scanners took no network"
  fi

  jq -n \
    --argjson seq "$SEQ" \
    --arg verdict "$result" \
    --arg bundle_file "$(basename "$BUNDLE")" \
    --arg bundle_sha256 "${BUNDLE_SHA:-unknown}" \
    --arg base "${BASE:-}" \
    --arg head "${HEAD_SHA:-}" \
    --arg gitleaks "$gl_ver" \
    --arg opengrep "$og_ver" \
    --arg trivy "$tv_ver" \
    --argjson trivy_db "$trivy_db_meta" \
    --arg rules_sha256 "$rules_sha" \
    --arg rules_commit "$rules_commit" \
    --arg script_version "$AIRLOCK_SCRIPT_VERSION" \
    --arg net "$net" \
    --argjson counts "${COUNTS_JSON:-null}" \
    --argjson unresolved "${TRIVY_UNRESOLVED_JSON:-null}" \
    --argjson findings "$(json_array_of ${FINDINGS+"${FINDINGS[@]}"})" \
    --argjson flags "$(json_array_of ${FLAGS+"${FLAGS[@]}"})" \
    --arg reviewer "${AIRLOCK_REVIEWER:-unassigned} (provenance label, not an attestation)" \
    --arg at "$(now_iso)" \
    '{
      schema: "airlock/verdict/1",
      seq: $seq,
      verdict: $verdict,
      bundle_file: $bundle_file,
      bundle_sha256: $bundle_sha256,
      base: (if $base == "" then null else $base end),
      head_sha: (if $head == "" then null else $head end),
      scanners: {
        gitleaks: $gitleaks,
        opengrep: $opengrep,
        opengrep_rules: { sha256: $rules_sha256, source_commit: $rules_commit },
        trivy: { version: $trivy, db: $trivy_db }
      },
      finding_counts: $counts,
      trivy_unresolved_offline: $unresolved,
      blocking_findings: $findings,
      flags_for_reviewer: $flags,
      network: $net,
      script_version: $script_version,
      reviewer: $reviewer,
      decided_at: $at
    }' > "$IN/verdict.json"

  log ""
  if [[ "$result" == PASS ]]; then
    printf '%s  VERDICT: PASS  %s seq %s  head %s\n' "$_c_grn" "$_c_off" "$SEQ" "${HEAD_SHA:-?}" >&2
  else
    printf '%s  VERDICT: FAIL  %s seq %s\n' "$_c_red" "$_c_off" "$SEQ" >&2
  fi
  log "verdict: $IN/verdict.json"
  [[ "$result" == PASS ]] || exit 2
  exit 0
}

step "Station 2 - quarantine - seq $SEQ"

# ---------------------------------------------------------------------------
# 0. Refresh the read-only mirror of GitLab. Forced and pruned, so a previous
#    run can never leave the mirror ahead of GitLab.
# ---------------------------------------------------------------------------
if [[ $REFRESH -eq 1 ]]; then
  [[ -n "${QUARANTINE_REMOTE:-}" ]] || die "QUARANTINE_REMOTE is not set (read-only deploy token URL for the GitLab project)"
  if [[ ! -d "$MIRROR" ]]; then
    log "cloning the GitLab project into the quarantine mirror"
    git clone --quiet --mirror "$QUARANTINE_REMOTE" "$MIRROR"
  else
    git -C "$MIRROR" remote set-url origin "$QUARANTINE_REMOTE"
    git -C "$MIRROR" fetch --quiet --prune --force origin '+refs/*:refs/*'
  fi
  ok "mirror refreshed from GitLab"
else
  [[ -d "$MIRROR" ]] || die "--no-refresh but there is no mirror at $MIRROR"
  warn "mirror NOT refreshed (offline run)"
fi

GITLAB_MAIN="$(git -C "$MIRROR" rev-parse --verify --quiet "refs/heads/$BRANCH" || true)"
if [[ -n "$GITLAB_MAIN" ]]; then
  ok "GitLab $BRANCH is $GITLAB_MAIN"
else
  ok "GitLab project is empty (no refs/heads/$BRANCH)"
fi

# ---------------------------------------------------------------------------
# 1. Digest. Binds everything that follows to these exact bytes rather than to a
#    filename. It detects corruption, and via this verdict it detects a swap
#    between scan and import. It does NOT detect tampering in transit: the
#    digest rides the same medium as the bundle.
# ---------------------------------------------------------------------------
BUNDLE_SHA="$(sha256_of "$BUNDLE")"
MANIFEST_SHA="$(jget "$MANIFEST" .bundle_sha256)"
if [[ "$BUNDLE_SHA" != "$MANIFEST_SHA" ]]; then
  record_fail "checksum mismatch: bundle is $BUNDLE_SHA, manifest says $MANIFEST_SHA"
  emit_verdict FAIL
fi
if [[ -f "$BUNDLE.sha256" ]]; then
  ( cd "$IN" && sha256sum -c --status "$(basename "$BUNDLE").sha256" ) || {
    record_fail "the sidecar .sha256 file does not match the bundle"
    emit_verdict FAIL
  }
fi
ok "sha256 matches the manifest: $BUNDLE_SHA"

# ---------------------------------------------------------------------------
# 2. Sequence. Refuse a replay or an out-of-order number before anything is
#    unpacked. The airlock/seq/<n> tags in GitLab are the ledger.
# ---------------------------------------------------------------------------
if git -C "$MIRROR" rev-parse --verify --quiet "refs/tags/airlock/seq/$SEQ" >/dev/null; then
  record_fail "seq $SEQ was already accepted (tag airlock/seq/$SEQ exists in GitLab) - replay refused"
  emit_verdict FAIL
fi
# strip=4 drops refs/tags/airlock/seq/ and leaves the bare number.
HIGHEST="$(git -C "$MIRROR" for-each-ref --format='%(refname:strip=4)' 'refs/tags/airlock/seq/*' | sort -n | tail -1)"
if [[ -n "${HIGHEST:-}" ]] && [[ "$SEQ" -le "$HIGHEST" ]]; then
  record_fail "out-of-order sequence: seq $SEQ, but airlock/seq/$HIGHEST is already accepted"
  emit_verdict FAIL
fi
ok "sequence $SEQ is next (highest accepted: ${HIGHEST:-none})"

# ---------------------------------------------------------------------------
# 3. Prerequisites, taken from the bundle's own header. Asserting against the
#    bundle beats asserting against the manifest; the manifest is only as
#    trustworthy as the digest that travelled beside it. The manifest's own
#    base field is cross-checked against it.
# ---------------------------------------------------------------------------
PREREQS="$(bundle_prereqs "$BUNDLE")"
PREREQ_COUNT="$(printf '%s\n' "$PREREQS" | grep -c . || true)"
MANIFEST_BASE="$(jget "$MANIFEST" .base)"

if [[ -z "$GITLAB_MAIN" ]]; then
  # Baseline. An empty project has no main, so there is nothing to continue from
  # and nothing to open a merge request into.
  [[ "$PREREQ_COUNT" -eq 0 ]] || record_fail "GitLab has no $BRANCH, but the bundle declares $PREREQ_COUNT prerequisite(s)"
  [[ "$MANIFEST_BASE" == "null" ]] || record_fail "GitLab has no $BRANCH, but the manifest declares base $MANIFEST_BASE"
  BASE=""
  have_findings && emit_verdict FAIL
  ok "baseline: empty project, bundle has no prerequisites"
else
  [[ "$PREREQ_COUNT" -eq 1 ]] || record_fail "expected exactly 1 prerequisite, the bundle declares $PREREQ_COUNT"
  BASE="$(printf '%s\n' "$PREREQS" | head -1)"
  [[ "$BASE" == "$GITLAB_MAIN" ]] || record_fail "bundle continues from ${BASE:-nothing} but GitLab $BRANCH is $GITLAB_MAIN - it cannot fast-forward"
  [[ "$MANIFEST_BASE" == "$BASE" ]] || record_fail "manifest base $MANIFEST_BASE does not match the bundle prerequisite $BASE"
  have_findings && emit_verdict FAIL
  ok "bundle continues exactly from GitLab $BRANCH"
fi

# ---------------------------------------------------------------------------
# 4. Unpack, in a throwaway clone of the mirror so a FAIL cannot poison the next
#    run's comparison. fsck on, and a refspec ALLOWLIST, not a wildcard: a
#    wildcard would import refs/replace/*, which git log and git diff honour by
#    default, letting a bundle change what the merge-request diff shows the
#    reviewer without changing a single commit.
#
#    fsck validates that objects are well formed, not that their content is
#    safe. It is an integrity check, not a security check.
# ---------------------------------------------------------------------------
rm -rf "$WORK" "$TREE"
git clone --quiet --mirror "$MIRROR" "$WORK"
git -C "$WORK" remote remove origin 2>/dev/null || true

BUNDLE_REFS="$(git -C "$WORK" bundle list-heads "$BUNDLE" | awk '{print $2}' | sort)"
REFSPECS=("refs/heads/$BRANCH:refs/heads/$BRANCH")
if printf '%s\n' "$BUNDLE_REFS" | grep -q '^refs/tags/'; then
  REFSPECS+=('refs/tags/*:refs/tags/*')
fi

while read -r r; do
  [[ -n "$r" ]] || continue
  case "$r" in
    "refs/heads/$BRANCH"|refs/tags/*) ;;
    *) record_fail "bundle carries a ref outside the allowlist: $r" ;;
  esac
done <<< "$BUNDLE_REFS"
have_findings && emit_verdict FAIL

if ! clean_env git -c fetch.fsckObjects=true -C "$WORK" fetch --quiet "$BUNDLE" "${REFSPECS[@]}"; then
  record_fail "unbundling failed object integrity checking (fsck) or the refspec allowlist"
  emit_verdict FAIL
fi
ok "unpacked with fsck on; refs limited to $BRANCH and named tags"

HEAD_SHA="$(git -C "$WORK" rev-parse --verify "refs/heads/$BRANCH")"
MANIFEST_HEAD="$(jget "$MANIFEST" .head_sha)"
[[ "$HEAD_SHA" == "$MANIFEST_HEAD" ]] || record_fail "unpacked head $HEAD_SHA does not match manifest head_sha $MANIFEST_HEAD"

# Ref-set assertion. This is what catches git's silent drop of a requested ref
# that points at an object excluded by a ^ exclusion (a new tag on old history),
# and any extra ref smuggled in beside the ones the manifest declares.
MANIFEST_REFS="$(jget "$MANIFEST" .refs | jq -r 'keys[]' | sort)"
if [[ "$BUNDLE_REFS" != "$MANIFEST_REFS" ]]; then
  record_fail "ref set mismatch - manifest: [$(printf '%s ' $MANIFEST_REFS)] bundle: [$(printf '%s ' $BUNDLE_REFS)]"
fi
while read -r r; do
  [[ -n "$r" ]] || continue
  want="$(jq -r --arg k "$r" '.refs[$k] // ""' "$MANIFEST")"
  got="$(git -C "$WORK" rev-parse --verify --quiet "$r" || echo "")"
  [[ "$want" == "$got" ]] || record_fail "ref $r is ${got:-absent} after unpacking, manifest says $want"
done <<< "$MANIFEST_REFS"
have_findings && emit_verdict FAIL
ok "ref set matches the manifest exactly"

RANGE_DESC="all history up to $HEAD_SHA"
[[ -n "$BASE" ]] && RANGE_DESC="$BASE..$HEAD_SHA"
ok "range under review: $RANGE_DESC"

# ---------------------------------------------------------------------------
# 5. Suppression files and inline annotations. A change to any of these is a
#    change to what the scanners are allowed to see, so it blocks. On the
#    baseline every file is an addition, so their mere presence needs a one-time
#    reviewer waiver instead.
# ---------------------------------------------------------------------------
SUPPRESSIONS=(.gitleaksignore .gitleaks.toml .semgrepignore .opengrepignore .trivyignore)
if [[ -n "$BASE" ]]; then
  while read -r f; do
    [[ -n "$f" ]] && record_fail "scanner suppression file changed inside the range: $f"
  done < <(git -C "$WORK" diff --name-only --diff-filter=AMD "$BASE" "$HEAD_SHA" -- "${SUPPRESSIONS[@]}" || true)
  DIFF_TEXT="$(git -C "$WORK" diff "$BASE" "$HEAD_SHA" || true)"
else
  while read -r f; do
    [[ -n "$f" ]] || continue
    if [[ "$WAIVE_BASELINE_SUPPRESSIONS" == "1" ]]; then
      record_flag "baseline carries $f - cleared by a one-time reviewer waiver recorded in this verdict"
    else
      record_fail "baseline carries $f - re-run with --waive-baseline-suppressions to record a reviewer waiver"
    fi
  done < <(git -C "$WORK" ls-tree -r --name-only "$HEAD_SHA" -- "${SUPPRESSIONS[@]}" || true)
  DIFF_TEXT=""
fi

# Inline annotations are not filenames and would otherwise slip past a filename rule.
if [[ -n "$DIFF_TEXT" ]]; then
  while read -r hit; do
    [[ -n "$hit" ]] && record_flag "inline scanner suppression in the diff: $hit"
  done < <(printf '%s\n' "$DIFF_TEXT" | grep -nE 'gitleaks:allow|nosemgrep|trivy:ignore' | head -20 || true)

  # Pipeline files, submodules and binaries are flagged for the human reviewer,
  # not blocked.
  while read -r f; do
    [[ -n "$f" ]] || continue
    case "$f" in
      .gitlab-ci.yml|.github/workflows/*|.gitmodules|Dockerfile|*/Dockerfile|docker-compose*.yml|docker-compose*.yaml)
        record_flag "reviewer attention: $f changed" ;;
    esac
  done < <(git -C "$WORK" diff --name-only "$BASE" "$HEAD_SHA" || true)
fi

# ---------------------------------------------------------------------------
# 6. Scan. Three scanners, three different scopes. "Scan the new commits" is
#    only correct for one of them. Every one takes its configuration from the
#    station, never from the repository, and runs with a scrubbed environment.
# ---------------------------------------------------------------------------
git -C "$WORK" worktree add --quiet --detach "$TREE" "$HEAD_SHA"
trap 'git -C "$WORK" worktree remove --force "$TREE" >/dev/null 2>&1 || true' EXIT

step "gitleaks - history-scoped over $RANGE_DESC"
GL_LOGOPTS="$HEAD_SHA"
[[ -n "$BASE" ]] && GL_LOGOPTS="$BASE..$HEAD_SHA"
set +e
clean_env gitleaks git "$TREE" \
  --config="$GITLEAKS_TOML" \
  --log-opts="$GL_LOGOPTS" \
  --report-format=json --report-path="$REPORTS/gitleaks.json" \
  --no-banner --exit-code=0
GL_RC=$?
set -e
[[ $GL_RC -eq 0 ]] || record_fail "gitleaks exited $GL_RC (scanner error, not a finding)"
GL_COUNT="$(jq 'length' "$REPORTS/gitleaks.json" 2>/dev/null || echo 0)"

step "opengrep - tree at $HEAD_SHA"
set +e
clean_env opengrep scan \
  --config="$RULES" \
  --json --json-output="$REPORTS/opengrep.json" \
  --no-error --disable-version-check --quiet \
  "$TREE" > /dev/null
OG_RC=$?
set -e
[[ $OG_RC -le 1 ]] || record_fail "opengrep exited $OG_RC (scanner error, not a finding)"
OG_ERROR="$(jq '[.results[]? | select(.extra.severity == "ERROR")] | length' "$REPORTS/opengrep.json" 2>/dev/null || echo 0)"
OG_WARN="$(jq '[.results[]? | select(.extra.severity == "WARNING")] | length' "$REPORTS/opengrep.json" 2>/dev/null || echo 0)"
OG_INFO="$(jq '[.results[]? | select(.extra.severity == "INFO")] | length' "$REPORTS/opengrep.json" 2>/dev/null || echo 0)"

step "trivy - state-based over the tree, offline"
set +e
clean_env trivy fs "$TREE" \
  --scanners vuln,secret,misconfig \
  --skip-db-update --skip-java-db-update --offline-scan \
  --format json --output "$REPORTS/trivy.json" \
  --quiet --exit-code 0
TV_RC=$?
set -e
[[ $TV_RC -eq 0 ]] || record_fail "trivy exited $TV_RC (scanner error, not a finding)"
TV_HIGH="$(jq '[ .Results[]?.Vulnerabilities[]?, .Results[]?.Misconfigurations[]? | select((.Severity // "") == "HIGH" or (.Severity // "") == "CRITICAL") ] | length' "$REPORTS/trivy.json" 2>/dev/null || echo 0)"
TV_SECRETS="$(jq '[ .Results[]?.Secrets[]? ] | length' "$REPORTS/trivy.json" 2>/dev/null || echo 0)"

# --offline-scan suppresses the API and remote parent-POM lookups a Maven project
# needs to resolve a dependency tree, so an offline run can return a thin result
# that reads as a clean PASS. Make that visible instead.
TRIVY_UNRESOLVED_JSON="$(jq -c '[ .Results[]? | select(.Class == "lang-pkgs") | select((.Vulnerabilities // []) | length == 0) | {target: .Target, type: .Type} ]' "$REPORTS/trivy.json" 2>/dev/null || echo null)"
if [[ "$TRIVY_UNRESOLVED_JSON" != "[]" ]] && [[ "$TRIVY_UNRESOLVED_JSON" != "null" ]]; then
  record_flag "trivy returned no vulnerability data for some dependency targets offline; see trivy_unresolved_offline"
fi

COUNTS_JSON="$(jq -n \
  --argjson gl "$GL_COUNT" --argjson oge "$OG_ERROR" --argjson ogw "$OG_WARN" \
  --argjson ogi "$OG_INFO" --argjson tvh "$TV_HIGH" --argjson tvs "$TV_SECRETS" \
  '{gitleaks: $gl, opengrep: {error: $oge, warning: $ogw, info: $ogi}, trivy: {high_or_critical: $tvh, secrets: $tvs}}')"

# ---------------------------------------------------------------------------
# 7. Blocking policy. Provisional lab default until the security team sets the
#    real thresholds. The station has to emit PASS or FAIL to run at all.
# ---------------------------------------------------------------------------
if [[ "$GL_COUNT" -gt 0 ]]; then
  record_fail "gitleaks: $GL_COUNT secret finding(s) - $(jq -r '[.[] | "\(.Commit[0:12]) \(.File) [\(.RuleID)]"] | unique | join("; ")' "$REPORTS/gitleaks.json")"
fi
[[ "$TV_SECRETS" -gt 0 ]] && record_fail "trivy: $TV_SECRETS secret finding(s) in the tree at head"
[[ "$TV_HIGH"    -gt 0 ]] && record_fail "trivy: $TV_HIGH HIGH or CRITICAL finding(s)"
[[ "$OG_ERROR"   -gt 0 ]] && record_fail "opengrep: $OG_ERROR ERROR-severity finding(s)"
[[ "$OG_WARN"    -gt 0 ]] && record_flag "opengrep: $OG_WARN WARNING finding(s) - flagged, not blocking"

log ""
log "counts: $COUNTS_JSON"
have_findings && emit_verdict FAIL
emit_verdict PASS
