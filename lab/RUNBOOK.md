# Airlock lab runbook

Every command needed to set the lab up and to drive the demonstration, in order.
Run them in Git Bash from the `lab` directory unless a step says otherwise.

The lab plays three parts on one PC. Keep them straight while presenting, because
the separation is the thing being demonstrated:

| Part | Where it runs | What it holds |
|---|---|---|
| Developer zone, outside | Git Bash on the host | GitHub push rights. No GitLab credentials at all. |
| Security station, the gate | The `airlock-station` container | A read-only mirror of GitLab. No write credentials anywhere. |
| GitLab, inside | The `airlock-gitlab` container | The protected `main`. Reachable on 127.0.0.1 only. |

Two shells make the demo easier to follow: one for the developer zone and one for
the inside. Both need the credentials loaded:

```bash
cd ~/eclipse-workspace/Hub2Lab/lab
source .secrets
source demo.env
```

`.secrets` is written by the bootstrap and holds the GitLab tokens. `demo.env`
names the GitHub repository the demo exports from and defines `accepted`, which
prints the commit GitLab last accepted. Every export after the baseline takes
`--base $(accepted)`, so no SHA is ever typed by hand.

## Prerequisites

- Docker Desktop with the WSL2 backend, memory ceiling at least 8 GB in
  `%UserProfile%\.wslconfig`. Below that GitLab is killed part way through its
  first boot and then serves a confusing 502.
- Git for Windows, with Git Credential Manager already signed in to GitHub.
- An **empty private** repository at `https://github.com/krixerx/airlock-demo-source`:
  no README, no `.gitignore`, no licence. This is the stand-in for the developers'
  GitHub repository outside the wall, so it holds the migration project, not this
  one. Keep it private: it is seeded from a real project and the stages commit
  things nobody wants indexed. The name lives in `lab/demo.env`, nowhere else.
- About 15 GB of free disk, and 20 minutes for the first boot and the image build.

## Part A. One-time setup

Only needed once per PC. Skip to part B if `docker compose ps` already shows both
containers.

```bash
cd ~/eclipse-workspace/Hub2Lab/lab
cp .env.example .env          # then fill in both passwords, generated not invented
docker compose up -d gitlab
```

GitLab's first boot takes 5 to 10 minutes. The bootstrap waits for it, so there is
nothing to watch. Then:

```bash
scripts/gitlab-bootstrap.sh
```

This creates the group, the empty project, the two people and their tokens, and
writes `lab/.secrets`. Read its output once: it prints the sign-in details for
`importer` (Developer) and `secreviewer` (Maintainer).

Branch protection is deliberately **not** applied here. An empty project has no
`main` to protect. It is applied in stage 1, on screen, which makes it a visible
one-time step rather than a hole someone spots later.

Then build and start the gate:

```bash
source .secrets
docker compose up -d --build station
```

The build pulls gitleaks, opengrep and trivy at pinned versions and bakes the
opengrep rules and both trivy databases into the image. Inside a customer network
this image is what crosses the airlock; nothing fetches anything at scan time.

Check it:

```bash
docker compose ps
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8929/users/sign_in   # 200
```

## Part B. Seed the GitHub side

Once, after creating the empty private repository:

```bash
source demo.env
scripts/demo-seed.sh baseline
```

This copies the real `adabas-to-oracle-migration` history into the demo repository
unchanged: 15 commits, nothing squashed, nothing rewritten. It records the
baseline commit in `lab/demo/baseline.sha`, which `demo-seed.sh reset` uses to put
GitHub back between rehearsals.

`demo-seed.sh` is not part of the airlock. It only plays the part of the
developers who push to GitHub, so each stage has something real to export.

## Part C. The demonstration

Roughly 20 minutes. Each stage below gives the commands, then the line to look for
in the output.

### Stage 1. Baseline import

The whole repository crosses for the first time. No merge request: an empty
project has no `main`, so there is nothing to open one into.

```bash
# Developer zone
scripts/airlock-export.sh --seq 1 --base none
```

> `OK  15 commit(s), 178715 bytes` and a `sha256`. A whole project history is
> under 200 KB (the exact byte count varies a little with git's packing). Show the three files in `transfer/seq-0001`: the bundle, its
> checksum, and the manifest.

```bash
# The gate
docker compose exec station airlock-scan.sh 1
```

> `VERDICT: PASS`. Above it, the checks in order: the bundle's own prerequisites
> against GitLab's current state, unpack with fsck on and refs limited to `main`,
> then the three scanners.

```bash
# Inside. The reviewer pushes the baseline, then locks the branch.
scripts/airlock-import.sh 1 --baseline
scripts/gitlab-protect.sh
scripts/airlock-confirm.sh 1
```

> `main: nobody pushes, Maintainers merge, fast-forward only, force push off`,
> then the two SHAs side by side and `identical SHA`.

Applying protection on screen, immediately after the baseline, is worth saying out
loud: from this point nobody can push to `main`, not the Maintainer, not root.

### Stage 2. An incremental update, the happy path

```bash
# Developer zone. Two ordinary commits appear on GitHub.
scripts/demo-seed.sh stage2
scripts/airlock-export.sh --seq 2 --base $(accepted)
```

> `2 commit(s), 1346 bytes`. The bundle carries only what is new. This is the
> number that answers "how do we move updates across, week after week".

```bash
docker compose exec station airlock-scan.sh 2
scripts/airlock-import.sh 2
```

> `pushed incoming/2 and opened a merge request into main`, then
> `main is unchanged until a Maintainer merges it`.

Open the merge request in the browser as `secreviewer`. It carries the bundle
digest, the base, the head, the commit count and the verdict in its description.
Read the diff, merge it, and point out that the merge method is fast-forward only,
so no merge commit is created and the SHA cannot drift.

```bash
scripts/airlock-confirm.sh 2
```

> The two SHAs, `identical SHA`, and `recorded airlock/seq/2 in GitLab`.

### Stage 3. The gate works

The beat that earns credibility with a security audience. Do not cut it, and show
the remediation, not just the block.

A developer commits the migration account's Oracle password inline in a loader
script:

```bash
scripts/demo-seed.sh stage3-secret
scripts/airlock-export.sh --seq 3 --base $(accepted)
docker compose exec station airlock-scan.sh 3
```

> `FAIL  gitleaks: 1 secret finding(s) - <commit> scripts/load-to-target.ps1
> [generic-api-key]`. The verdict names the commit and the file, so the developer
> knows what to fix without anyone forwarding the code back out.

Say why it is a password and not an AWS key. GitHub's own push protection matches
provider-issued credentials and blocks those at `git push`, on private
repositories too, so the airlock would never see one. It does not match this, and
neither does trivy or opengrep. The only thing standing between that password and
the internal GitLab is the history-scoped gitleaks pass at the gate.

Now the fix a developer would try first:

```bash
scripts/demo-seed.sh stage3-removal
scripts/airlock-export.sh --seq 3 --base $(accepted)
docker compose exec station airlock-scan.sh 3
```

> Still `FAIL`, and the verdict still names the earlier commit, the one that
> introduced the password. The files at the head are clean now. The password is in
> the history, and history is what crosses.

And the fix that works. Only commits the security team has never accepted are
rewritten, so the last accepted commit stays an ancestor and the fast-forward
inside GitLab is still possible:

```bash
AIRLOCK_LAST_ACCEPTED=$(accepted) scripts/demo-seed.sh stage3-rewrite
scripts/airlock-export.sh --seq 3 --base $(accepted)
docker compose exec station airlock-scan.sh 3
```

> `VERDICT: PASS`. Then import, merge as the reviewer, and confirm as in stage 2.

```bash
scripts/airlock-import.sh 3
# merge the MR in the browser as secreviewer
scripts/airlock-confirm.sh 3
```

### Stage 4. Nobody bypasses

Run this while a merge request is open, so the audience can see both refusals
against a live request.

```bash
# The importer holds Developer. Push straight to main:
scripts/airlock-import.sh 3 --direct-to-main
```

> `remote: GitLab: You are not allowed to push code to protected branches on this
> project.` followed by `pre-receive hook declined`, and the script reports
> `GitLab refused the direct push to main, as it should`.

```bash
# The importer merges their own merge request:
curl -sS -X PUT -H "PRIVATE-TOKEN: $IMPORTER_TOKEN" \
  "$GITLAB_URL/api/v4/projects/$GITLAB_PROJECT_ID/merge_requests/<iid>/merge"
```

> `{"message":"401 Unauthorized"}`. Only the Maintainer merges, and the Maintainer
> is the security team.

### Stage 5. The receipt closes the loop, and a replay is refused

Re-present a bundle that has already been accepted:

```bash
docker compose exec station airlock-scan.sh 3
```

> `FAIL  seq 3 was already accepted (tag airlock/seq/3 exists in GitLab) - replay
> refused`. The ledger lives in GitLab as the `airlock/seq/<n>` tags, so the gate
> refuses a replay even after the quarantine mirror is thrown away and re-cloned.

Note that this rewrites `transfer/seq-0003/verdict.json` to FAIL, which is correct
but means the seq-3 evidence no longer shows the PASS. Do this beat last, or copy
the directory first if the PASS verdict is needed afterwards.

Then show what each transfer leaves behind:

```bash
ls transfer/seq-0002
cat transfer/seq-0002/receipt.json
```

> `manifest.json` (what was sent), `verdict.json` (what the gate decided, with the
> scanner versions and the rules digest), `receipt.json` (what was accepted, and
> the base for the next export). Three files, no database, readable in five years.

## Part D. Between rehearsals

Put GitHub back to the baseline commit, and the lab back to "nothing has ever
crossed":

```bash
source .secrets
source demo.env
scripts/demo-seed.sh reset
scripts/airlock-reset.sh --yes
docker compose up -d --force-recreate station
source .secrets            # the reset minted new tokens
```

`airlock-reset.sh` deletes the GitLab project and re-bootstraps, so the 5 to 10
minute GitLab boot is not repeated. It takes about a minute. The station must be
recreated afterwards because it holds the old read-only deploy token in its
environment.

To stop everything without losing the lab:

```bash
docker compose stop
```

## Part E. When something goes wrong

**GitLab serves 502 for a long time after `docker compose up`.** First boot takes
5 to 10 minutes and a restart takes 2 to 3. If it never resolves, raise the WSL2
memory ceiling in `%UserProfile%\.wslconfig` and restart Docker Desktop.

**The bootstrap says there is no root account.** GitLab's first-boot seed refuses
a password it considers a common word combination, and it fails quietly:
reconfigure reports success and the instance simply has no users. Choose a less
word-like `GITLAB_ROOT_PASSWORD` in `lab/.env` and re-run the bootstrap, which
re-seeds by itself.

**The bootstrap cannot create the project, "path has already been taken".** A
deleted GitLab project keeps its path reserved: it is renamed to
`<path>-deletion_scheduled-<id>` and a redirect route is left behind on the old
path, so a direct lookup answers 302 and reports the deleted project as if it were
alive. `scripts/airlock-reset.sh --yes` removes those permanently and waits for the
path to come free. The removal itself is asynchronous in GitLab, so right after a
container restart it can take a few minutes while Sidekiq catches up.

**The station cannot reach GitLab, or pushes are refused as unauthorised.** The
station holds the deploy token in its environment, so it keeps the old one across a
re-bootstrap. `docker compose up -d --force-recreate station`.

**`airlock-export.sh` refuses with "base is NOT an ancestor".** This is not a bug.
Someone rewrote history that the security team has already accepted, so the
fast-forward inside GitLab is now impossible. Do not export. The re-baseline
procedure in the design document applies.

**A `demo-seed.sh` push is refused with "push declined due to repository rule
violations".** GitHub push protection found something it recognises as a real
credential. It applies to private repositories as well, so making the repository
private is not a way around it. Stage 3 plants a database password precisely
because GitHub does not match that shape; if you change the planted secret to a
provider key, expect this.

## What is pinned, and what does not update

`station/Dockerfile` pins every tool and both trivy databases, and the verdict
records all of them, so a decision can always be tied to the code and the rules
that produced it.

One of those pins is permanent rather than merely current.
`opengrep/opengrep-rules` was archived on 2025-11-28. Moving to
`semgrep/semgrep-rules` is not an option: on 2024-12-13, the day Opengrep forked
it, Semgrep relicensed that repository from LGPL-2.1 plus Commons Clause to the
Semgrep Rules License v1.0, which permits internal use only and forbids
redistribution. The station image is built to be carried into a customer network,
so it must carry rules it is allowed to redistribute, and the fork is the last such
snapshot. Rule freshness is therefore a stated limitation of the static analysis
layer. gitleaks and trivy keep their own updatable data, and the offline refresh
route for those is a follow-up in the design document.
