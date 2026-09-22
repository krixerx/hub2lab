#!/usr/bin/env bash
#
# One-time lab bootstrap: create the group, the EMPTY project, the two people,
# their credentials, and the station's read-only deploy token.
#
# Deliberately not the branch protection. Protection is applied by
# gitlab-protect.sh immediately after the baseline push, because an empty project
# has no main to protect yet, and because doing it on screen makes the bootstrap
# a visible one-time step rather than a hole someone spots later.
#
#   scripts/gitlab-bootstrap.sh
#
source "$(dirname "${BASH_SOURCE[0]}")/airlock-lib.sh"

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GITLAB_URL="${GITLAB_URL:-http://127.0.0.1:8929}"
GROUP_PATH="${AIRLOCK_GROUP:-airlock}"
PROJECT_PATH="${AIRLOCK_PROJECT:-adabas-to-oracle-migration}"
CONTAINER="${AIRLOCK_GITLAB_CONTAINER:-airlock-gitlab}"
LAB_PASSWORD="${AIRLOCK_USER_PASSWORD:-}"
API="$GITLAB_URL/api/v4"

# Lab settings live in lab/.env, which stays on this PC. Reading them here keeps
# the password for the two lab accounts out of a script that is published.
if [[ -f "$LAB_ROOT/.env" ]]; then
  set -a; source "$LAB_ROOT/.env"; set +a
  LAB_PASSWORD="${AIRLOCK_USER_PASSWORD:-$LAB_PASSWORD}"
fi
[[ -n "$LAB_PASSWORD" ]]   || die "set AIRLOCK_USER_PASSWORD in lab/.env - 16 or more random characters, because GitLab refuses passwords it reads as a word combination"

# The sign-in page, not /-/readiness: the health endpoints are IP-restricted by
# default and answer 404 to anything outside the allowlist, which looks exactly
# like "still booting" and never resolves.
gitlab_http() { curl -s -o /dev/null -w '%{http_code}' "$GITLAB_URL/users/sign_in" || true; }

step "Waiting for GitLab to finish booting (first boot takes 5 to 10 minutes)"
for i in $(seq 1 120); do
  [[ "$(gitlab_http)" == "200" ]] && break
  printf '  %4ds  HTTP %s\n' "$((i * 10))" "$(gitlab_http)" >&2
  sleep 10
done
[[ "$(gitlab_http)" == "200" ]] \
  || die "GitLab is still not serving. Check: docker compose logs -f gitlab"
ok "GitLab is up at $GITLAB_URL"

# ---------------------------------------------------------------------------
# An admin token, minted through the Rails console. This is the only step that
# needs the console; everything after it is the documented REST API.
# ---------------------------------------------------------------------------
# GitLab's first-boot seed creates the root account, and it refuses a password it
# considers a common word combination. When it refuses, the seed fails quietly:
# reconfigure reports success, every service runs, and the instance simply has no
# users at all. Re-running the seed after fixing the password is the fix.
step "Checking the root account exists"
if ! docker exec "$CONTAINER" gitlab-rails runner 'exit(User.exists?(username: "root") ? 0 : 1)' 2>/dev/null; then
  warn "no root account - the first-boot seed was refused, probably GITLAB_ROOT_PASSWORD. Re-seeding."
  docker exec "$CONTAINER" gitlab-rake db:seed_fu 2>&1 | grep -iE 'administrator|password must' | sed 's/^/    /' >&2
  docker exec "$CONTAINER" gitlab-rails runner 'exit(User.exists?(username: "root") ? 0 : 1)' \
    || die "root still not created - choose a less word-like GITLAB_ROOT_PASSWORD in lab/.env and re-run"
fi
ok "root account present"

step "Minting an admin token"
ROOT_TOKEN="$(docker exec "$CONTAINER" gitlab-rails runner \
  "t = User.find_by_username('root').personal_access_tokens.create!(scopes: ['api'], name: 'airlock-lab-bootstrap', expires_at: 30.days.from_now); puts t.token" \
  2>/dev/null | tr -d '\r' | tail -1)"
[[ -n "$ROOT_TOKEN" ]] || die "could not mint a root token"
ok "admin token minted"

api() {  # api <METHOD> <path> [curl args...]
  local method="$1" path="$2"; shift 2
  curl -sS -X "$method" -H "PRIVATE-TOKEN: $ROOT_TOKEN" "$API$path" "$@"
}
# Tolerant by design. A GET on a path GitLab holds a redirect route for answers
# with a 302 and an empty body, which is not JSON; that is a "not there", not a
# reason to abort the bootstrap.
jfield() { python -c '
import json, sys
try:
    d = json.loads(sys.stdin.read() or "null")
except ValueError:
    d = None
print(d.get(sys.argv[1], "") if isinstance(d, dict) else "")
' "$1"; }

# Look a project up by listing the group, never by GETting /projects/<path>.
# After a delete GitLab renames it to <path>-deletion_scheduled-<id> and keeps a
# redirect route on the old path, so the direct lookup reports the corpse as if
# it were alive. The listing carries the real path and the deletion marker.
find_project_id() {
  api GET "/groups/$GROUP_ID/projects?per_page=100" | python -c '
import json, sys
want = sys.argv[1]
try:
    items = json.loads(sys.stdin.read() or "[]")
except ValueError:
    items = []
for p in items if isinstance(items, list) else []:
    if p.get("path") == want and not p.get("marked_for_deletion_on"):
        print(p["id"])
        break
' "$PROJECT_PATH"
}

# Make "main" the instance default, so the empty project agrees with the branch
# everything else in this lab names.
api PUT /application/settings -d "default_branch_name=main" >/dev/null
ok "instance default branch name is main"

step "Group and project"
GROUP_ID="$(api GET "/groups/$GROUP_PATH" | jfield id)"
if [[ -z "$GROUP_ID" ]]; then
  GROUP_ID="$(api POST /groups -d "name=Airlock" -d "path=$GROUP_PATH" -d "visibility=private" | jfield id)"
fi
[[ -n "$GROUP_ID" ]] || die "could not create or find the group"
ok "group $GROUP_PATH (id $GROUP_ID)"

PROJECT_ID="$(find_project_id)"
if [[ -z "$PROJECT_ID" ]]; then
  # No README, no .gitignore, no licence. The project must be empty: the baseline
  # bundle is the first thing that ever enters it, and any commit created inside
  # would break SHA equality with GitHub permanently.
  CREATE_JSON="$(api POST /projects \
    -d "name=$PROJECT_PATH" \
    -d "path=$PROJECT_PATH" \
    -d "namespace_id=$GROUP_ID" \
    -d "initialize_with_readme=false" \
    -d "visibility=private" \
    -d "merge_method=ff" \
    -d "remove_source_branch_after_merge=true" \
    -d "builds_access_level=disabled" \
    -d "wiki_access_level=disabled" \
    -d "snippets_access_level=disabled" \
    -d "packages_enabled=false")"
  PROJECT_ID="$(printf '%s' "$CREATE_JSON" | jfield id)"
fi
[[ -n "$PROJECT_ID" ]] \
  || die "could not create the project: ${CREATE_JSON:-no response}
  If that says the path has already been taken, a deleted project still holds it.
  Run scripts/airlock-reset.sh --yes, which now removes those permanently."
ok "project $GROUP_PATH/$PROJECT_PATH (id $PROJECT_ID), empty, merge method fast-forward"

step "People"
make_user() {  # make_user <username> <name> <access_level>
  local uname="$1" fullname="$2" level="$3" uid
  uid="$(api GET "/users?username=$uname" | python -c 'import json,sys; u=json.load(sys.stdin); print(u[0]["id"] if u else "")')"
  if [[ -z "$uid" ]]; then
    uid="$(api POST /users \
      -d "email=$uname@airlock.lab" \
      -d "username=$uname" \
      -d "name=$fullname" \
      -d "password=$LAB_PASSWORD" \
      -d "skip_confirmation=true" | jfield id)"
  fi
  [[ -n "$uid" ]] || die "could not create user $uname"
  api POST "/projects/$PROJECT_ID/members" -d "user_id=$uid" -d "access_level=$level" >/dev/null 2>&1 || true
  printf '%s' "$uid"
}

IMPORTER_ID="$(make_user importer "Importer (Developer)" 30)"
REVIEWER_ID="$(make_user secreviewer "Security reviewer (Maintainer)" 40)"
ok "importer  = Developer  (id $IMPORTER_ID) - can push branches, cannot merge"
ok "secreviewer = Maintainer (id $REVIEWER_ID) - the only role that can merge into main"

step "Credentials"
mint_token() {  # mint_token <user_id> <name>
  api POST "/users/$1/impersonation_tokens" \
    -d "name=$2" -d "scopes[]=api" -d "scopes[]=write_repository" \
    -d "expires_at=$(date -u -d '+30 days' +%Y-%m-%d 2>/dev/null || date -u -v+30d +%Y-%m-%d)" | jfield token
}
IMPORTER_TOKEN="$(mint_token "$IMPORTER_ID" airlock-lab-importer)"
REVIEWER_TOKEN="$(mint_token "$REVIEWER_ID" airlock-lab-reviewer)"
[[ -n "$IMPORTER_TOKEN" && -n "$REVIEWER_TOKEN" ]] || die "could not mint user tokens"

# The station gets read_repository and nothing else. It executes scanners over
# untrusted incoming code, so it must not hold anything that can write to GitLab.
DEPLOY_JSON="$(api POST "/projects/$PROJECT_ID/deploy_tokens" \
  -d "name=airlock-station-readonly" -d "scopes[]=read_repository" -d "username=airlock-station")"
DT_USER="$(printf '%s' "$DEPLOY_JSON" | jfield username)"
DT_TOKEN="$(printf '%s' "$DEPLOY_JSON" | jfield token)"
[[ -n "$DT_TOKEN" ]] || die "could not create the station deploy token: $DEPLOY_JSON"
ok "station deploy token created, scope read_repository only"

# The station reaches GitLab by its compose hostname over the lab network.
QUARANTINE_REMOTE="http://$DT_USER:$DT_TOKEN@gitlab:8929/$GROUP_PATH/$PROJECT_PATH.git"

umask 077
cat > "$LAB_ROOT/.secrets" <<ENVFILE
# Lab credentials. Local to this PC, never committed. Source before running the
# host-side stations:   source lab/.secrets
export GITLAB_URL='$GITLAB_URL'
export GITLAB_PROJECT='$GROUP_PATH/$PROJECT_PATH'
export GITLAB_PROJECT_ID='$PROJECT_ID'
export GITLAB_ADMIN_TOKEN='$ROOT_TOKEN'
export IMPORTER_USER='importer'
export IMPORTER_TOKEN='$IMPORTER_TOKEN'
export REVIEWER_USER='secreviewer'
export REVIEWER_TOKEN='$REVIEWER_TOKEN'
export AIRLOCK_UI_PASSWORD='$LAB_PASSWORD'
ENVFILE

python - "$LAB_ROOT/.env" "$QUARANTINE_REMOTE" <<'PY'
import sys, pathlib
env, remote = pathlib.Path(sys.argv[1]), sys.argv[2]
lines = [l for l in env.read_text(encoding="utf-8").splitlines() if not l.startswith("QUARANTINE_REMOTE=")]
lines.append("QUARANTINE_REMOTE=" + remote)
env.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
PY

ok "wrote lab/.secrets and set QUARANTINE_REMOTE in lab/.env"
log ""
log "Sign in at $GITLAB_URL"
log "  importer    / $LAB_PASSWORD   (Developer)"
log "  secreviewer / $LAB_PASSWORD   (Maintainer)"
log ""
log "Next:  source lab/.secrets"
log "       docker compose up -d station"
