#!/usr/bin/env bash
#
# Demo choreography for the GitHub side of the airlock.
#
# The airlock stations never touch this script: it only plays the part of the
# developers who push to GitHub, so that each demo stage has something real to
# export. It runs on the host, outside the customer network, and needs GitHub
# push rights (Git Credential Manager already holds them on the demo PC).
#
#   demo-seed.sh baseline          # copy the real history into the demo repo
#   demo-seed.sh stage2            # two clean commits
#   demo-seed.sh stage3-secret     # one commit carrying a database password
#   demo-seed.sh stage3-removal    # the wrong fix: delete it in a later commit
#   demo-seed.sh stage3-rewrite    # the real fix: it never existed
#   demo-seed.sh status            # what GitHub main looks like now
#   demo-seed.sh reset             # back to the baseline commit, force-pushed
#
# The demo repository must be PRIVATE: it is seeded from a real project and the
# stages commit things nobody wants indexed. The secret stage plants a database
# password rather than a provider key, because GitHub push protection blocks a
# provider key at push time, on private repositories too.
#
source "$(dirname "${BASH_SOURCE[0]}")/airlock-lib.sh"

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_URL="${AIRLOCK_DEMO_SOURCE:-https://github.com/krixerx/adabas-to-oracle-migration}"
DEMO_URL="${AIRLOCK_SOURCE_URL:-https://github.com/krixerx/airlock-demo-source}"
WORK="$LAB_ROOT/demo/work"
BRANCH=main

STAGE="${1:-}"
[[ -n "$STAGE" ]] || { sed -n '2,25p' "$0"; exit 1; }
shift || true
while (($#)); do
  case "$1" in
    --source) SOURCE_URL="$2"; shift 2 ;;
    --demo)   DEMO_URL="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# Every commit made here is authored by the developer persona, not by whoever is
# driving the keyboard.
git_demo() { git -C "$WORK" -c user.name='Demo Developer' -c user.email='dev@example.invalid' "$@"; }

open_work() {
  [[ -d "$WORK/.git" ]] || die "no demo clone yet - run: scripts/demo-seed.sh baseline"
  git_demo remote set-url origin "$DEMO_URL"
  git_demo fetch --quiet --prune origin
  git_demo checkout --quiet "$BRANCH"
  git_demo reset --quiet --hard "origin/$BRANCH"
}

show_head() {
  printf '  github  %s  %s  %s\n' "$BRANCH" "$(git_demo rev-parse HEAD)" "$(git_demo log -1 --format=%s)" >&2
}

case "$STAGE" in

# ---------------------------------------------------------------------------
# The baseline is the real project history, pushed into the demo repository
# unchanged. Nothing is rewritten and nothing is squashed: the point of the demo
# is that a real repository crosses, and that its whole history exports as a
# bundle small enough to carry on anything.
# ---------------------------------------------------------------------------
baseline)
  step "Seeding $DEMO_URL from $SOURCE_URL"
  # Plain ls-remote, not --exit-code: an empty repository has no refs, and
  # --exit-code reports that as failure, which is exactly the state we want.
  git ls-remote "$DEMO_URL" >/dev/null 2>&1 \
    || die "cannot reach $DEMO_URL - create it first as an EMPTY PRIVATE repository: no README, no .gitignore, no licence"

  rm -rf "$LAB_ROOT/demo"
  mkdir -p "$LAB_ROOT/demo"
  git clone --quiet "$SOURCE_URL" "$WORK"
  git_demo remote set-url origin "$DEMO_URL"

  if git ls-remote --heads "$DEMO_URL" "$BRANCH" | grep -q .; then
    warn "$DEMO_URL already has $BRANCH - leaving it alone. Use 'reset' to put it back to the baseline."
    git_demo fetch --quiet origin
    git_demo reset --quiet --hard "origin/$BRANCH"
  else
    git_demo push --quiet origin "HEAD:refs/heads/$BRANCH"
  fi
  git_demo branch --quiet --set-upstream-to "origin/$BRANCH" "$BRANCH" 2>/dev/null || true

  BASELINE="$(git_demo rev-parse HEAD)"
  printf '%s\n' "$BASELINE" > "$LAB_ROOT/demo/baseline.sha"
  ok "$BRANCH is $BASELINE ($(git_demo rev-list --count HEAD) commits)"
  log ""
  log "Next:  scripts/airlock-export.sh --seq 1 --base none"
  ;;

# ---------------------------------------------------------------------------
# Stage 2. Two ordinary commits, the kind the gate is meant to wave through.
# ---------------------------------------------------------------------------
stage2)
  step "Stage 2 - two clean commits"
  open_work

  cat > "$WORK/hop/sql/25_vehicle_reconcile.sql" <<'SQL'
-- Row-count reconciliation for the vehicle load.
--
-- Run after 20_vehicle.sql. A difference here means rows were dropped between
-- staging and the target, which the pipeline itself does not report.
SELECT 'VEHICLE' AS table_name,
       (SELECT COUNT(*) FROM stg_vehicle) AS staged,
       (SELECT COUNT(*) FROM vehicle)     AS loaded,
       (SELECT COUNT(*) FROM stg_vehicle)
         - (SELECT COUNT(*) FROM vehicle) AS missing
FROM dual;
SQL
  git_demo add hop/sql/25_vehicle_reconcile.sql
  git_demo commit --quiet -m "Add a row-count reconciliation query for the vehicle load"

  cat >> "$WORK/README.md" <<'MD'

## Reconciling a load

After `20_vehicle.sql`, run `25_vehicle_reconcile.sql`. It compares the staged
row count with the loaded one. A non-zero `missing` means rows were dropped
between staging and the target, which the pipeline does not report on its own.
MD
  git_demo add README.md
  git_demo commit --quiet -m "Document the reconciliation step"

  git_demo push --quiet origin "$BRANCH"
  ok "pushed 2 commits"
  show_head
  ;;

# ---------------------------------------------------------------------------
# Stage 3. The commit that must not get through: the migration account's Oracle
# password, inline in a loader script.
#
# A password is the deliberate choice. GitHub's own push protection matches
# provider-issued credentials, so it blocks an AWS key before the airlock ever
# sees it, and a sceptic can fairly say GitHub already handles that case. It does
# not match this, and neither does trivy or opengrep. Only the history-scoped
# gitleaks pass catches it, which is exactly the class of secret the gate exists
# for.
#
# The value is generated per run rather than written out. A fixed one would be a
# credential-shaped string sitting in this repository, and running this project's
# own gate over this repository is the honest test of that.
# ---------------------------------------------------------------------------
stage3-secret)
  step "Stage 3 - a commit carrying the target database password"
  open_work

  # Windows Python writes CRLF; the CR would end up inside the password.
  ORA_PASSWORD="$(python -c "import secrets,string; print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(32)))" | tr -d '\r')"
  [[ ${#ORA_PASSWORD} -eq 32 ]] || die "could not generate the demo password"

  cat > "$WORK/scripts/load-to-target.ps1" <<'PS1'
# Loads the nightly extract files into the target Oracle schema.
#
# Usage: .\load-to-target.ps1 -Path .\data\extract

param([string]$Path = ".\data\extract")

$TargetUser     = "MIGRATION"
$TargetPassword = "__ORA_PASSWORD__"
$TargetDsn      = "oracle-prod.internal:1521/ORCLPDB"

Get-ChildItem -Path $Path -Filter *.dat | ForEach-Object {
    sqlldr "$TargetUser/$TargetPassword@$TargetDsn" `
        control="hop/ctl/$($_.BaseName).ctl" data=$_.FullName
}
PS1
  sed -i "s|__ORA_PASSWORD__|$ORA_PASSWORD|" "$WORK/scripts/load-to-target.ps1"
  ! grep -q '__ORA_PASSWORD__' "$WORK/scripts/load-to-target.ps1"     || die "the placeholder was not substituted - stage 3 would prove nothing"
  git_demo add scripts/load-to-target.ps1
  git_demo commit --quiet -m "Add the loader for the nightly extract"
  git_demo push --quiet origin "$BRANCH"
  warn "pushed a commit containing the target database password - the gate must FAIL this bundle"
  show_head
  ;;

# ---------------------------------------------------------------------------
# The plausible wrong fix. Deleting the password in a later commit changes
# nothing: the bundle still carries the commit that introduced it.
# ---------------------------------------------------------------------------
stage3-removal)
  step "Stage 3 - the password is removed in a later commit"
  open_work

  cat > "$WORK/scripts/load-to-target.ps1" <<'PS1'
# Loads the nightly extract files into the target Oracle schema.
#
# The password comes from the ORACLE_MIGRATION_PASSWORD environment variable,
# never from this file.
#
# Usage: .\load-to-target.ps1 -Path .\data\extract

param([string]$Path = ".\data\extract")

$TargetUser     = "MIGRATION"
$TargetPassword = $env:ORACLE_MIGRATION_PASSWORD
$TargetDsn      = "oracle-prod.internal:1521/ORCLPDB"

if (-not $TargetPassword) {
    throw "ORACLE_MIGRATION_PASSWORD is not set"
}

Get-ChildItem -Path $Path -Filter *.dat | ForEach-Object {
    sqlldr "$TargetUser/$TargetPassword@$TargetDsn" `
        control="hop/ctl/$($_.BaseName).ctl" data=$_.FullName
}
PS1
  git_demo add scripts/load-to-target.ps1
  git_demo commit --quiet -m "Read the migration password from the environment"
  git_demo push --quiet origin "$BRANCH"
  warn "pushed the removal - the gate must still FAIL, the password is in the history"
  show_head
  ;;

# ---------------------------------------------------------------------------
# The fix that works. Only commits the security team has never accepted are
# rewritten, so the last accepted commit stays an ancestor of main and the
# fast-forward inside GitLab is still possible.
# ---------------------------------------------------------------------------
stage3-rewrite)
  step "Stage 3 - rewriting the unaccepted commits so the password never existed"
  open_work
  BASE="${AIRLOCK_LAST_ACCEPTED:-}"
  [[ -n "$BASE" ]] \
    || die "set AIRLOCK_LAST_ACCEPTED to the last accepted commit (lab/transfer/state/last-accepted.json, field accepted_sha)"
  git_demo merge-base --is-ancestor "$BASE" HEAD \
    || die "$BASE is not an ancestor of $BRANCH - wrong base"

  # Keep the working tree exactly as it is now (the loader without the password),
  # throw away the two commits that carried and then deleted it, and commit the
  # result once.
  git_demo reset --quiet --soft "$BASE"
  git_demo commit --quiet -m "Add the loader for the nightly extract

The password comes from the environment. This replaces the two commits that
carried it inline and then removed it. Neither was ever accepted."
  git_demo push --quiet --force-with-lease origin "$BRANCH"
  ok "force-pushed the rewritten history - no commit carries the password now"
  show_head
  ;;

status)
  open_work
  show_head
  git_demo log --oneline -8 | sed 's/^/    /' >&2
  ;;

reset)
  step "Putting $DEMO_URL back to the baseline commit"
  [[ -d "$WORK/.git" ]] || die "no demo clone - run: scripts/demo-seed.sh baseline"
  BASELINE="$(cat "$LAB_ROOT/demo/baseline.sha" 2>/dev/null || true)"
  [[ -n "$BASELINE" ]] || die "no lab/demo/baseline.sha - re-run: scripts/demo-seed.sh baseline"
  git_demo remote set-url origin "$DEMO_URL"
  git_demo fetch --quiet origin
  git_demo checkout --quiet "$BRANCH"
  git_demo reset --quiet --hard "$BASELINE"
  git_demo push --quiet --force origin "$BRANCH"
  ok "$BRANCH is back at $BASELINE"
  ;;

*)
  die "unknown stage: $STAGE"
  ;;
esac
