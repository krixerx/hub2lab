# Hub2Lab

A proof of concept for moving code from GitHub into an internal GitLab that
cannot reach the internet, through a gate the security team controls.

Development happens on GitHub. The target environment runs a local GitLab that no
developer machine can reach, and new code may enter it only after the security
team has looked at it. This repository holds the proposed process, a working
laboratory that runs it end to end on one Windows PC, and the material for
presenting it.

## The process, in four stations

1. **Developer zone.** Export everything since the last accepted commit as an
   incremental git bundle, with a manifest and a SHA-256.
2. **Security station.** A quarantine container, not GitLab. It verifies the
   digest, checks the bundle continues from GitLab's current `main`, unpacks it
   with git's object integrity checks on, and scans the new commits with gitleaks,
   Opengrep and Trivy. The result is PASS or FAIL.
3. **GitLab.** A bundle that passed is pushed as `incoming/<n>` with a merge
   request into a protected `main`. Nobody can push to `main`. Only a Maintainer
   can merge, fast-forward only.
4. **Confirmation.** Compare GitLab's `main` with the head the exporter declared,
   record the `airlock/seq/<n>` ledger tag, and write the receipt that becomes the
   base for the next export.

The load-bearing property is that the commit SHA inside equals the commit SHA
outside. Git is content addressed, so equal SHAs mean the histories are identical
byte for byte, and no diff review is needed to establish it.

## What is here

| Path | What it is |
|---|---|
| `docs/designs/github-to-gitlab-airlock.md` | The design: problem, approaches considered, the chosen one, open questions. |
| `docs/draftSpec.md` | The task as specified, with acceptance criteria in Gherkin. |
| `docs/airlock-presentation.md` | The slide content for the security review. |
| `lab/RUNBOOK.md` | **Start here to run anything.** Every command, in order, with the expected output. |
| `lab/docker-compose.yml` | Local GitLab CE and the security station. |
| `lab/station/` | The station image: gitleaks, Opengrep and Trivy, all pinned, rules and databases baked in. |
| `lab/scripts/` | The four stations, the GitLab bootstrap, the reset, and the demo choreography. |

## Running it

Docker Desktop, Git for Windows, and about 20 minutes for the first boot. Then
follow `lab/RUNBOOK.md` from part A.

Nothing in this repository is production shaped. It is a demonstration rig: GitLab
is bound to 127.0.0.1, the credentials are lab credentials, and the security
station holds no write access to anything.
