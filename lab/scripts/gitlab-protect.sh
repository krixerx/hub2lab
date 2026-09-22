#!/usr/bin/env bash
#
# Applied immediately after the baseline push, and never relaxed afterwards
# except as a recorded re-baseline event.
#
# GitLab applies its own default protection the moment a default branch is first
# created, so main is never truly unprotected - but the default lets Maintainers
# push, which is not what this design wants. This replaces it.
#
#   scripts/gitlab-protect.sh
#
source "$(dirname "${BASH_SOURCE[0]}")/airlock-lib.sh"

GITLAB_URL="${GITLAB_URL:-http://127.0.0.1:8929}"
API="$GITLAB_URL/api/v4"
TOKEN="${GITLAB_ADMIN_TOKEN:?source lab/.secrets first}"
PID="${GITLAB_PROJECT_ID:?source lab/.secrets first}"
BRANCH=main

api() { local m="$1" p="$2"; shift 2; curl -sS -X "$m" -H "PRIVATE-TOKEN: $TOKEN" "$API$p" "$@"; }

step "Protecting $BRANCH"

# Remove whatever GitLab created by default when the branch first appeared.
api DELETE "/projects/$PID/protected_branches/$BRANCH" >/dev/null 2>&1 || true

# push_access_level 0  = No one may push, not even a Maintainer, not even root.
# merge_access_level 40 = Maintainers may merge. Only the security team holds it.
# This is the Community Edition substitute for Premium approval rules, and the
# security team has to accept the substitution explicitly.
RESP="$(api POST "/projects/$PID/protected_branches" \
  -d "name=$BRANCH" \
  -d "push_access_level=0" \
  -d "merge_access_level=40" \
  -d "allow_force_push=false")"
printf '%s\n' "$RESP" | python -m json.tool 2>/dev/null | sed 's/^/    /' >&2 || printf '%s\n' "$RESP" >&2

# Fast-forward only is half of the load-bearing property: no merge commit is ever
# created, so the merged SHA is the SHA that came out of GitHub.
api PUT "/projects/$PID" \
  -d "merge_method=ff" \
  -d "only_allow_merge_if_all_discussions_are_resolved=true" \
  -d "remove_source_branch_after_merge=true" >/dev/null

step "Effective settings"
api GET "/projects/$PID/protected_branches" | python -m json.tool | sed 's/^/    /' >&2
api GET "/projects/$PID" | python -c '
import json,sys
p = json.load(sys.stdin)
for k in ("merge_method","default_branch","builds_access_level","only_allow_merge_if_all_discussions_are_resolved"):
    print("    %-48s %s" % (k, p.get(k)))
' >&2

ok "main: nobody pushes, Maintainers merge, fast-forward only, force push off"
