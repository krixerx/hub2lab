#!/usr/bin/env bash
#
# Wipe the lab back to "GitLab is running, nothing has ever crossed" and
# re-bootstrap it. Use this to rehearse the demo end to end more than once.
#
# It deletes the GitLab PROJECT, not the GitLab instance, so the five to ten
# minute first boot is not repeated.
#
#   scripts/airlock-reset.sh          # asks first
#   scripts/airlock-reset.sh --yes
#
source "$(dirname "${BASH_SOURCE[0]}")/airlock-lib.sh"

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GITLAB_URL="${GITLAB_URL:-http://127.0.0.1:8929}"
API="$GITLAB_URL/api/v4"

if [[ "${1:-}" != "--yes" ]]; then
  log "This deletes the GitLab project, every bundle in lab/transfer, the"
  log "quarantine mirror and the exporter mirror, then re-bootstraps the lab."
  read -r -p "Type 'reset' to continue: " answer
  [[ "$answer" == "reset" ]] || die "cancelled"
fi

step "Deleting the GitLab project"
if [[ -n "${GITLAB_ADMIN_TOKEN:-}" && -n "${GITLAB_PROJECT:-}" ]]; then
  PROJECT_PATH="${GITLAB_PROJECT##*/}"
  GROUP_PATH="${GITLAB_PROJECT%%/*}"
  ENC="$(printf '%s' "$GITLAB_PROJECT" | sed 's|/|%2F|')"

  gapi() { local method="$1" path="$2"; shift 2; curl -sS -X "$method" -H "PRIVATE-TOKEN: $GITLAB_ADMIN_TOKEN" "$API$path" "$@"; }

  # Everything the group still holds under this path, alive or pending deletion.
  # The trailing tr is not decoration: Windows Python writes CRLF, and mapfile
  # below strips only the LF. The CR then rides along inside the project path and
  # curl rejects the URL it is pasted into, silently, because the call is a
  # best-effort one. Command substitution would have dropped it; mapfile does not.
  # A GET on /projects/<path> proves nothing here: GitLab renames a deleted
  # project to <path>-deletion_scheduled-<id> and keeps a redirect route on it,
  # so the direct lookup answers 302 and reports the corpse as if it were alive.
  survivors() {
    gapi GET "/groups/$GROUP_PATH/projects?per_page=100" | python -c '
import json, sys
want = sys.argv[1]
try:
    items = json.loads(sys.stdin.read() or "[]")
except ValueError:
    items = []
for p in items if isinstance(items, list) else []:
    path = p.get("path", "")
    if path == want or (path.startswith(want + "-") and p.get("marked_for_deletion_on")):
        print(p["id"], p["path_with_namespace"])
' "$PROJECT_PATH" | tr -d '
'
  }

  gapi DELETE "/projects/$ENC" >/dev/null 2>&1 || true

  # The first delete only marks the project and reserves its path. Remove it for
  # good, otherwise the re-create in the bootstrap is refused with
  # "path has already been taken".
  # GitLab only queues the destroy; Sidekiq does the work, and right after a
  # container restart that queue can take minutes to drain. Keep asking.
  rows=(); LAST_RESP=""
  for _ in $(seq 1 60); do
    mapfile -t rows < <(survivors)
    ((${#rows[@]})) || break
    for row in "${rows[@]}"; do
      read -r pid pfull <<<"$row"
      # Keep the last answer. If the loop gives up, this is the only thing that
      # explains why, and a silent best-effort delete is how a broken URL went
      # unnoticed once already.
      LAST_RESP="$(gapi DELETE "/projects/$pid?permanently_remove=true&full_path=$pfull" 2>&1 || true)"
    done
    sleep 5
  done
  if ((${#rows[@]} == 0)); then
    ok "project deleted, path $GITLAB_PROJECT is free"
  else
    die "the path is still held by: ${rows[*]}
  last answer from GitLab: ${LAST_RESP:-none}
  Delete it in the admin UI (Admin > Projects > Deleted projects) and re-run."
  fi
else
  warn "no admin token in the environment - source lab/.secrets first, or delete the project in the UI"
fi

step "Clearing local state"
rm -rf "$LAB_ROOT/transfer"/* "$LAB_ROOT/quarantine"/* "$LAB_ROOT/exporter" "$LAB_ROOT/importer"
ok "transfer, quarantine, exporter and importer directories emptied"

step "Re-bootstrapping"
bash "$LAB_ROOT/scripts/gitlab-bootstrap.sh"

log ""
log "The station container holds the OLD deploy token in its environment."
log "Pick up the new one with:   docker compose up -d --force-recreate station"
