# Design: Controlled GitHub to internal GitLab code transfer (Airlock)

Status: **APPROVED** 2026-09-21 (revision 3; two adversarial review rounds, 6/10 then 7/10, 49 issues applied)
Based on: `docs/draftSpec.md` (v0.1, same date). That document remains the source of the
acceptance criteria; this one adds the prior-art survey, the mechanism specification and
the presentation plan.

## Problem Statement

A delivery team works on a customer contract. The customer requires that final builds and
tests run inside their network, which has no internet access. The customer's opening
position was that all development happen inside their office, on their old desktops,
without internet or AI, verbatim: *"but so we can never succeed with the project."* The
team negotiated a concession, verbatim: *"they allowed us to develop outside and bring
bundle or batches which first need to pass security review and after that gets merged to
customer internal gitlab."*

The concession is granted, so nobody needs persuading that the idea is good. What does not
exist is the workflow. There is no agreed, repeatable way to move an update across the
boundary, and no evidence chain proving that what landed in GitLab is what was scanned and
approved. Transfers will run weekly, possibly daily, for the life of the contract, so
every decision has to survive that repetition.

The immediate deliverable is a presentation of how the workflow would work, backed by a
lab on one Windows PC that makes it credible. The lab is evidence, not the product.

## Target User

Two audiences, two different fears.

- **The security reviewer at the customer.** Must say yes. Their fear is twofold: can they
  trust what enters, and how much recurring work does this put on their desk. At daily
  cadence, the review burden is the thing most likely to kill this in month three. It will
  not surface in the lab, because in the lab the reviewer is you.
- **The delivery team.** Their fear is round-trip latency. A transfer that takes two days
  to clear means the inside environment is permanently stale.

**Scope decision: no narrowing of the demo.** A narrower demo was considered and rejected.
The presentation covers the full path: initial code transport, security check, incremental
bundle transport. The reason is that the room needs to see the whole path, not a slice.

## Scope

Carried forward from `docs/draftSpec.md`, with three changes marked below.

**In scope**

- GitLab CE running locally in Docker Desktop, reachable on localhost only.
- A lab project with two roles. The **importer** has the Developer role and cannot merge.
  The **security reviewer** has the Maintainer role and is the only one who can merge.
- Protected `main`: nobody can push, only Maintainers can merge, merge method is
  fast-forward only, force push off.
- The export, scan, import and confirm steps, against one test repository on GitHub.
- The six acceptance scenarios in `docs/draftSpec.md`, plus two added here: an offline scan
  run, and a replayed bundle refused. Both are listed under Success Criteria.

**Out of scope**

- Production GitLab installation, backup, high availability, LDAP or SSO.
- Migration of GitHub issues, pull requests, wikis and releases.
- **GitLab CI pipelines and runners.** The lab's story ends when approved code sits in
  GitLab. Nothing in the lab executes that code. Stated explicitly because it is the first
  thing a security audience asks after the merge.
- Building and testing inside the customer network. Deferred by decision, verbatim:
  *"lets not try to build source code in local customer gitlab now, this is too big a
  topic, we'll handle this topic separately later."* One slide names the problem, its
  prerequisite (internal Maven and npm registries) and its owner.
- Git LFS objects and submodule contents, which a bundle does not carry.
- Splitting a bundle across multiple volumes. The lab handles single-volume bundles only;
  if the measured baseline exceeds the chosen medium's capacity, splitting and resume
  become a named follow-up, not a lab feature.

**Changed from the draft spec**

1. **semgrep is replaced by Opengrep.** The draft names semgrep in its approach, its
   technical notes (`.semgrepignore`) and an open question. The reasons are in "What
   Already Exists": registry rulesets cannot be cached for offline use, and the licensing
   change restricts commercial use of the rules. The ignore filename does **not** change
   with the tool; see the filename trap below.
2. **Offline updating of scanner rules and databases** was out of scope in the draft. It is
   promoted here to **named but not built**: the lab uses a fixed, copied rule and database
   set, and the production refresh route is described on a slide. Promoted because the
   customer will ask how the scanners stay current, and "we did not look at it" is a worse
   answer than "here is the route, it is a second transfer, and it is not built yet."
3. **Two acceptance scenarios added:** offline scan, and replayed bundle refused.

## Constraints

- One Windows PC. GitLab CE in Docker Desktop, bound to 127.0.0.1. GitLab version pinned.
- GitLab CE has no merge-request approval rules; those are Premium. The substitute is
  role-based: only the security team holds Maintainer, and only Maintainers can merge.
- **No internet inside the customer network. The LAN still works**, and GitLab lives on it.
  This distinction matters for how the offline claim is tested; see Success Criteria.
- Cadence weekly to daily, permanently.
- Transfer medium is not yet decided, and is not yours to decide. See the return-channel
  coupling under Open Questions, which depends on it.

## Premises

1. The concession is already won. The presentation makes the workflow operable and
   trustworthy; it does not argue for outside development.
2. The security reviewer is the person who has to say yes, and their recurring workload is
   the objection most likely to sink this later.
3. The full path is three stages: baseline import of the whole repo, security check, then
   incremental bundles on a weekly or daily rhythm.
4. Internal Maven and npm repositories are a customer prerequisite, outside this scope, but
   named in the presentation with an owner so a missing registry does not read as your
   failure.
5. Role-based approval in GitLab CE substitutes for Premium approval rules, and the
   security team has to accept that substitution.
6. **Branch discipline: nobody develops on GitLab `main`.** It is a read-only record of
   approved GitHub states. No commit may originate inside GitLab, including through the web
   editor or a branch created in the UI. This is load-bearing: the SHA-equality property
   dies permanently the first time anyone commits inside, and protected-branch settings
   alone do not prevent it.

## What Already Exists

Searched before committing to an approach. Summary: buy nothing.

**Wrong layer, and why it matters.**

- **Copybara** (Google) moves and transforms code between repositories where one is
  authoritative. It is effectively stateless because it stores sync state as a label in the
  destination's commit messages, which means it must read the destination. Its README
  documents no air-gap mode and no file-based transport. It solves "keep two reachable
  repos in sync with transformations", not "carry commits through a human review across a
  boundary". Revisit only if you later need to strip internal files before export.
- **Zarf** (Defense Unicorns) and **Hauler** (Rancher Government) are the mature, funded
  tools for low-side to high-side delivery, and both package *artifacts* for deployment:
  container images, charts, binaries. They do not move source commits into a git server for
  review. Wrong layer for this design, right layer for the deferred build-inside problem.
- **Cross domain solutions and data diodes** (OPSWAT, Advenica, 4Secure and others) are the
  commercial category: hardware-enforced one-way flow plus content inspection and
  sanitisation. If the customer already owns one, or is required to use one, this workflow
  rides on it rather than proposing its own medium.

**Right problem, wrong maturity.**

- **git-ibundle** (Rust, MIT) does incremental offline mirroring through a sequence of
  numbered ibundle files, one-way file transfer only, with the receiver verifying it holds
  the basis before applying. That is this design's receipt mechanism, already built. But it
  is 4 stars, 38 commits, and its README states Linux is best supported with only limited
  Windows testing. Not a dependency to put in front of a customer's security department.
  **Its value here is its bug list, adopted below.**
- **airgap-sync** (Node, MIT) implements nearly this exact flow, bundles plus an automatic
  merge request on the isolated side. 1 star, 2 commits, solo author. Not a dependency.

**Scanner findings that change the draft spec.**

- **gitleaks: keep.** Rules are embedded in the binary or loaded from local TOML, with no
  call out during a scan. Fully offline. Note its config precedence: `--config`, then
  `GITLEAKS_CONFIG`, then `GITLEAKS_CONFIG_TOML`, then a repo-resident `.gitleaks.toml`,
  then the embedded default. Three of those five are hijackable by the incoming repository
  or by an inherited environment, which is why the station passes `--config` explicitly and
  runs with a clean environment.
- **semgrep: replace with Opengrep.** Registry rulesets are not cached locally and are
  fetched at runtime, so named packs and auto config do not work air-gapped; you must point
  `--config` at a local rules directory. Separately, the December 2024 licensing change
  moved cross-function taint analysis and other features out of Semgrep CE and restricted
  commercial use of the rules, which is why Opengrep was forked from Semgrep v1.100.0 on
  23 January 2025 under LGPL-2.1 by a consortium of more than ten AppSec vendors, among
  them Aikido Security, Arnica, Amplify Security, Endor Labs, Jit, Kodem, Legit Security,
  Mobb and Orca Security. It is backward compatible with the rule format and with JSON and
  SARIF output.
  **The filename trap:** Opengrep still reads `.semgrepignore`, not `.opengrepignore`. The
  Opengrep repository ships a `.semgrepignore` itself. The only way to change the name is
  the `--semgrepignore-filename=<VAL>` flag. A blocking rule written against
  `.opengrepignore` would watch a file that never appears and miss the one that does.
- **trivy: keep, but budget for it.** Air-gap support is documented. The database is an OCI
  artifact on GHCR (`trivy-db:2`, and `trivy-java-db:1` for JVM projects), mirrored with
  `oras cp`, plus `--download-db-only`, `--skip-db-update`, `--skip-java-db-update` and
  `--offline-scan`. The database rebuilds every six hours.
  **Binary and database are a version pair.** Trivy hard-fails with *"The local DB has an
  old schema version which is not supported by the current version of Trivy CLI"* when they
  drift, and `--skip-db-update` does not rescue it. Transfer them together, pin them
  together, record them as one pair.
  **`--offline-scan` costs result quality for Java.** It suppresses the API and remote
  parent-POM lookups Maven projects need to resolve a dependency tree, so an offline run can
  return a thin result that reads as a clean PASS. Handled in the verdict schema below.

**Conclusion.** Transport is commodity (`git bundle`, solved for years). Scanning is
commodity (gitleaks, opengrep, trivy). Nobody sells the piece in the middle, and that is
not a market oversight: the missing piece is an auditable record linking a scan verdict to
a specific commit range and to the merge that landed it. That is policy-shaped, not
code-shaped, which is why organisations doing this ship it as a process document rather
than a product. Assemble the commodity parts and build only the evidence chain.

Sources: [Copybara](https://github.com/google/copybara),
[git-ibundle](https://github.com/drmikehenry/git-ibundle),
[airgap-sync](https://github.com/Napsta6100k/airgap-sync),
[Zarf](https://zarf.dev/), [Hauler](https://ranchergovernment.com/products/hauler),
[Trivy air-gap docs](https://trivy.dev/docs/v0.55/advanced/air-gap/),
[Semgrep offline caching issue](https://github.com/semgrep/semgrep/issues/3147),
[Opengrep launch, Kodem press release](https://www.kodemsecurity.com/resources/press-release-security-rivals-unite-to-launch-opengrep-following-semgrep-clampdown),
[Opengrep on SecurityWeek](https://www.securityweek.com/endor-labs-and-allies-launch-opengrep-reviving-true-oss-for-sast/),
[opengrep `.semgrepignore`](https://github.com/opengrep/opengrep/blob/main/.semgrepignore),
[OPSWAT on data diodes and CDS](https://www.opswat.com/blog/data-diodes-in-transfer-cds-securing-high-assurance-cross-domain-solutions),
[GitLab on air-gapped security scanning](https://about.gitlab.com/blog/tutorial-security-scanning-in-air-gapped-environments/).

## Approaches Considered

### Approach A: Commodity parts plus an evidence chain (CHOSEN)

Plain `git bundle` for transport. gitleaks, opengrep and trivy for scanning. Scripts for
the four stations. The only thing built from scratch is the evidence chain: manifest,
verdict, receipt.

**Effort: 7 to 9 working days for one person on a real repository**, or 4 to 5 days if the
test repository is deliberately small and scanner false-positive triage is timeboxed to
half a day with that repository named in advance. The variable is triage, not engineering:
tuning three scanners to a usable false-positive rate on a non-trivial codebase is
routinely more than a day on its own, and this design treats false positives as a
first-class problem rather than an edge case. Risk low.

### Approach B: Build the airlock as a real tool

A CLI with a manifest schema, signed PASS/FAIL reports and an append-only ledger of
accepted commits. Not chosen now: a week of tooling bet on a process the security
department has not agreed to, and it invites the room to review your tool instead of the
workflow. Revisit after approval; the evidence chain from A is its foundation, and its
signing is the named upgrade for the digest weakness described below.

### Approach C: Reviewer-first

Design the PASS/FAIL report and reviewer checklist first, minimal transport behind them.
Not chosen: thin on the baseline import stage, which the presentation requires. Its best
idea survives in A, because the report format is part of the evidence chain.

### Approach D: Signed release packages instead of bundles

Zarf-style: each update is a signed package with source, SBOM and scan reports, history
rebuilt inside. Not chosen: loses SHA equality with GitHub, which is the cleanest
verification property the design has.

### Approach E: Stand on git-ibundle

Not chosen on maturity and Windows support. Its two failure modes are adopted into A.

## Recommended Approach

### The load-bearing property, stated first

Protected `main` with **fast-forward only** merges creates no merge commit. Station 2
asserts that the bundle's prerequisites equal the current GitLab `main`, which guarantees
`incoming/<seq>` is a direct descendant, which is what makes the fast-forward possible.
Those two decisions together are what make GitLab `main` carry the **same commit SHA** as
GitHub `main`. Git is content-addressed, so an identical SHA means identical history, byte
for byte, all the way back. This is the verification property the whole design rests on.
Say it out loud on a slide.

Its cost is recoverability: fast-forward only, with force push off and no commits
originating inside, means there is no way out inside GitLab if accepted history is ever
rewritten. The re-baseline procedure below is the only exit, and it is a policy event.

### Station 1, developer zone (outside)

Export everything on `main` since the last accepted commit as an incremental bundle.

- **Refs that travel:** `main`, plus tags explicitly enumerated in the manifest. Nothing
  else. Feature branches must not ride along: station 3 only merges `main`, so any other
  branch would land inside having been read by nobody.
- Emit `manifest.json` and a SHA-256 of the bundle.
- **Before building the bundle, assert the last accepted SHA is still an ancestor of
  GitHub `main`.** If it is not, someone rewrote accepted history, the fast-forward inside
  is now impossible, and the re-baseline procedure applies. Do not produce a bundle.
- **Baseline (seq 1)** is the one case with no predecessor. Its manifest carries
  `"base": null` and the bundle has zero prerequisites.

### Station 2, security station (quarantine, not GitLab)

The quarantine is a **`--mirror` clone of the GitLab project**. It has to be: `git bundle
verify` only succeeds when the bundle's prerequisite commits already exist in the
repository it runs in, and the prerequisite assertion needs GitLab's current `main` to
compare against.

Refresh it read-only before each verification, forcing and pruning so a previous run cannot
leave it ahead of GitLab:

```
git fetch --prune --force origin '+refs/*:refs/*'
```

Then, **in a throwaway clone of the mirror, never in the mirror itself**, so that a FAIL
cannot poison the next run's comparison:

1. Verify the SHA-256 against `manifest.json`.
2. **Assert prerequisites.** Take the bundle's own prerequisite list from
   `git bundle verify <bundle>` output and require it to equal GitLab's current `main`.
   Cross-check the manifest's `base` field against that list, and treat a mismatch as a
   FAIL. Asserting against the bundle beats asserting against the manifest, because the
   manifest is no more trustworthy than the digest that travelled beside it.
   **For seq 1:** assert instead that the project has no `refs/heads/main` and that the
   bundle has zero prerequisites.
3. Unpack with object integrity checking on, and with a **refspec allowlist**, not a
   wildcard:

   ```
   git -c fetch.fsckObjects=true fetch <bundle> \
       'refs/heads/main:refs/heads/main' 'refs/tags/*:refs/tags/*'
   ```

   A wildcard `'refs/*:refs/*'` would import any namespace the bundle carries, including
   `refs/replace/*`. Replace refs are honoured by `git log` and `git diff` by default, so
   one could change what the merge-request diff shows the reviewer without changing a single
   commit. Reject that namespace by name, and put it on a slide: it is the most interesting
   attack the design defends against.
   Note for the reviewer's benefit that fsck validates that objects are well formed, not
   that their content is safe. It is an integrity check, not a security check.
4. **Assert the ref set.** Every ref in `manifest.json` must be present after unbundling,
   and any ref the bundle carries that is not in the manifest is a FAIL. This is what
   catches the second bundle failure mode below.
5. **Check the sequence.** Refuse a sequence number that is out of order, or one already
   recorded by an `airlock/seq/<n>` tag in the mirror.
6. Create a detached `git worktree` at the new head for the tree-based scanners, scan (see
   below), then remove the worktree.
7. Emit `verdict.json` with PASS or FAIL.

**The station holds no GitLab write credentials.** Its output is a verified bundle plus a
verdict. Pushing is a separate step, run by the importer with Developer-role credentials,
from outside the scan container. Putting write access to the inside GitLab into the same
container that executes scanners over untrusted incoming code is precisely the question the
security reviewer will ask, so do not do it and say so on the slide.

### Station 3, GitLab (inside)

The importer pushes a passed bundle's head as `incoming/<seq>` and opens a merge request
into protected `main`. The security reviewer reads the diff and merges, fast-forward only.

**Immediately after the merge**, the reviewer creates the tag `airlock/seq/<seq>` on the
project. That tag is the durable, reviewer-visible record of what has been accepted and it
survives a quarantine rebuild. It is a post-merge action with a named actor, because the
import step has already finished by then; in production a GitLab webhook can do it instead.

**Tags in the lab do not enter GitLab.** Manifest tags are scanned and asserted in station 2
but not pushed, because station 3 merges only `main` and a pushed tag would land without
appearing in the diff the reviewer read. Recorded as a limitation. In production the
importer pushes manifest tags after the merge and only when they point at commits already
accepted.

### Station 4, confirmation

Compare GitLab `main` after the merge against `head_sha` in `manifest.json`. Be precise
about what this is: from inside the network GitHub is unreachable, so the manifest value is
the only one available, and it travelled with the bundle. The comparison proves that what
merged is what the exporter said it was exporting. The demo adds the human confirmation by
showing GitHub's `main` SHA on screen beside it. Then emit `receipt.json`.

### The evidence chain

- **`manifest.json`** — source repo, base SHA (`null` for seq 1), head SHA, sequence number,
  the explicit list of commits, the explicit expected ref set, bundle SHA-256, bundle size
  in bytes, exporter identity, timestamp.
- **`verdict.json`** — the bundle SHA-256 it refers to, which is what binds a verdict to
  exact bytes rather than to a filename; scanner names and versions; the trivy
  binary-and-database pair with the database's age; a SHA-256 of the Opengrep rules
  directory archive plus the source commit of the rules repository (a copied directory has
  no version of its own); the airlock script version; findings; **what trivy could not
  resolve offline**, because an unresolved dependency tree is a flag, not a pass; PASS or
  FAIL; reviewer identity; timestamp.
- **`receipt.json`** — accepted commit SHA and sequence number, returned to the developer
  side. Answers the draft spec's open question about how the last accepted commit gets back
  out, and makes replay or reordering detectable.

**Honest limits of these artefacts, to state on the slide before someone else does:**

- The SHA-256 detects **corruption**, and via `verdict.json` it detects a **swap between
  scan and import**, because the verdict is produced inside the boundary. It does **not**
  detect tampering in transit: the digest rides the same medium as the bundle, so whoever
  can replace one can replace the other. The minimum upgrade is either an out-of-band
  digest or a detached signature with the exporter's public key pre-shared inside. That is
  Approach B's signing, and it is the first thing to build after approval.
- `exporter identity` and `reviewer identity` are **provenance labels, not attestations**,
  until signing exists. Label them that way in the doc and in the demo.

### Two `git bundle` failure modes to handle explicitly

Both are the reason git-ibundle exists, and its README states both. Handle them, or
incremental transfers break silently:

1. **Annotated tag objects cannot be bundle prerequisites**, only commits: *"Bundle files
   have no way to express a tag object as a prerequisite."* Enumerate tags explicitly in the
   manifest and assert their presence after unpacking.
2. ***"Git will remove any requested reference that points to an object excluded by any of
   the `^` exclusions."*** A new branch or tag pointing at older history is silently dropped
   from an incremental bundle. The manifest's expected ref set plus the station 2 assertion
   is the mitigation.

### When a bundle FAILs

- A FAIL **changes nothing inside**. The accepted base SHA and the sequence tag stay where
  they were. No branch is pushed. The sequence number is consumed, not reused.
- **The verdict has to get back out.** Without it the exporter does not know which commit
  and which file to fix. This is the same one-way problem as the receipt, and it is the
  more urgent of the two. See the return-channel question below.
- Remediation is a history rewrite on GitHub restricted to the **unaccepted** commits,
  because the secret remains in history until it does. This is the draft spec's fourth
  scenario, and its second half.
- The rewrite invalidates the SHAs of those commits, so the next export gets a fresh
  sequence number and the same base.

### The re-baseline procedure

This is the recovery path the design most needs, and the only exit when accepted history
has been rewritten. Station 1's ancestor assertion is what triggers it.

1. **Stop. Do not export.** A bundle built on rewritten accepted history cannot
   fast-forward and will wedge station 3.
2. **Treat it as a policy event, not a technical one.** Commits the security team already
   approved no longer exist. The reviewer decides whether that is acceptable at all, and
   the decision is recorded.
3. **Preferred remedy: go forward, do not rewrite.** Produce new commits on GitHub that
   reach the desired state without touching accepted history. The fast-forward property
   survives intact and no break-glass step is needed. Choose this every time you can.
4. **Break-glass remedy: a new baseline.** With protection temporarily relaxed by a
   Maintainer, GitLab `main` is reset to a fresh baseline import. Both the old and the new
   head SHAs, the reason, and the approving reviewer go into a re-baseline record beside the
   verdicts. The sequence counter **continues** rather than restarting, so the ledger stays
   monotonic and the gap is visible.
5. Step 4 breaks the "`main` is an unbroken record of approved states" property. That is
   why it needs a recorded decision and why step 3 exists.

### Scanning, per scanner

"Scan the new commits" is only correct for one of the three. They work differently:

- **gitleaks** is history-scoped: `gitleaks git --log-opts="<base>..<head>"`, with
  `--config` pointing at the **station's own** TOML.
- **Opengrep** scans a tree, not a commit range. Run it over the detached worktree at the
  new head, with `--config` pointing at the station's local rules directory.
- **trivy** is state-based. Run `trivy fs` over the detached worktree with
  `--skip-db-update`, `--skip-java-db-update` and `--offline-scan`. Over a commit range, a
  lockfile change is invisible. Without `--skip-java-db-update`, a JVM repository attempts a
  Java database download and fails offline.

**Every scanner takes its configuration from the station, never from the repository, and
the station runs with a clean environment** so `GITLEAKS_CONFIG` and `GITLEAKS_CONFIG_TOML`
cannot be inherited from anywhere. Repository-resident suppressions that must be treated as
blocking changes:

- `.gitleaksignore`, and a repo-resident `.gitleaks.toml` carrying an `[allowlist]` block.
- `.semgrepignore` (not `.opengrepignore`; see above). If you set
  `--semgrepignore-filename`, block that name too.
- `.trivyignore`.
- **Inline annotations**, which are not filenames and would otherwise slip past a filename
  rule: `gitleaks:allow` comments and `# nosemgrep` comments. Grep the incoming diff for
  them and flag every occurrence to the reviewer.

**The rule is about changes, with one exception for the baseline.** Any add, modify or
delete of those paths inside the commit range blocks the import. On seq 1 every file is an
addition, so a repository that has always carried a `.trivyignore` would be unable to make
its first import; there, their existence is flagged and cleared by a one-time reviewer
waiver recorded in the verdict.

Changes to pipeline files, submodules and binaries are flagged for the human reviewer.

**Lab default blocking policy, provisional until the security team sets it:** FAIL on any
gitleaks finding; FAIL on trivy HIGH or CRITICAL; FAIL on opengrep ERROR severity; flag but
do not block opengrep WARNING and INFO. The station has to emit PASS or FAIL to run at all,
so the lab needs a concrete rule even though the real one is the customer's to choose.

**False positives are a first-class problem, not an edge case.** "Any secret blocks" plus
"changes to the ignore files block" means every false positive is an unbypassable stop. Put
the allowlist **on the security station, under the reviewer's control**, never in the
repository, and express it as rule-id, path and regex entries in the station's TOML,
**never as `.gitleaksignore` fingerprints**: a fingerprint is keyed on commit SHA, file and
line, and the remediation path rewrites exactly those commits, so fingerprint entries
evaporate and the reviewer re-triages the same findings on every retry. Count observed false
positives in the lab and report the number; it is a direct input to the review-burden
question.

### Runtime environment

- Developer side: bash under Git for Windows.
- Security station: a **Linux container**, so gitleaks, opengrep and trivy are the same
  pinned binaries everywhere and Windows path and line-ending behaviour never enters the
  scan path.

### Setup steps (outline; the full version is a lab deliverable)

1. Docker Desktop with the WSL2 backend. Raise the memory ceiling in
   `%UserProfile%\.wslconfig` to at least 8 GB, or GitLab OOMs part way through first boot
   and serves a confusing 502.
2. GitLab CE at a pinned tag. Use **named Docker volumes** for `/var/opt/gitlab`,
   `/var/log/gitlab` and `/etc/gitlab`. Bind-mounting a Windows host path there fails on
   ownership and permissions.
3. Set `external_url` to match the published port, or GitLab advertises clone and push URLs
   that do not resolve from the host, and station 3 fails in a way that looks like a
   permissions problem.
4. First boot takes 5 to 10 minutes.
5. Create the project **with no initial commit** (no README, no `.gitignore`). Create two
   users: importer with Developer, security reviewer with Maintainer.
6. **Check the instance's initial default branch protection setting before the first push.**
   GitLab applies default protection the moment the default branch is created, so `main` is
   never truly unprotected; if the instance or group default is the fully-protected option,
   even the Maintainer's baseline push is refused and the bootstrap stalls in a way that
   looks like a bug. Confirm the setting, push the baseline as a Maintainer, then tighten
   `main` to Allowed-to-push: No one, Allowed-to-merge: Maintainers, fast-forward only,
   force push off.
7. Disable or forbid the web editor for `main`, and brief both users that no commit may
   originate inside GitLab (premise 6).
8. Build the station container with gitleaks, opengrep and trivy pinned, the rules directory
   copied in, and the trivy binary and both databases copied in as a pinned set.

### Presentation structure (full path, roughly 20 minutes)

- **Stage 0.** The problem, one minute. The alternative is old desktops with no internet.
- **Stage 1. Baseline import.** Full-repo bundle, checksum, scan, the reviewer pushes the
  baseline, protection is applied, SHA comparison. **There is no merge in the baseline**,
  and showing why is the point: an empty project has no `main`, so there is nothing to open
  a merge request into. Applying protection on screen afterwards makes it a visible one-time
  bootstrap rather than a hole someone spots later.
- **Stage 2. Incremental update, happy path.** Two new commits. The bundle contains only
  those two. The merge request is open. `main` is unchanged until the security reviewer
  merges. After the merge, SHAs match, and the reviewer tags `airlock/seq/2`.
- **Stage 3. The gate works.** A commit containing a secret is blocked, with commit and file
  named in the verdict. Then the follow-up beat: removing the secret in a later commit is
  still FAIL, because the secret remains in history, and it becomes PASS only after the
  unaccepted commits are rewritten. This is the beat that earns credibility with a security
  audience. Do not cut it, and do show the remediation, not just the block.
- **Stage 4. Nobody bypasses.** The importer, who holds Developer, tries to push directly to
  `main` and to merge the merge request. GitLab refuses both.
- **Stage 5. The receipt closes the loop**, and a replay is refused. Re-present an already
  accepted bundle; station 2 rejects it on the sequence tag.
- **Backup slides.** What the digest proves and what it does not, with the signing upgrade
  named. The `refs/replace/*` rejection. Corrupted or swapped bundle rejected. The
  re-baseline procedure. Limitations: LFS, submodules, tags not entering GitLab in the lab,
  single-volume bundles only. Offline scanner refresh route and its cadence. Prerequisites
  and owners, including the internal Maven and npm registries. Measured numbers: baseline
  bundle size, round-trip time, reviewer minutes, false-positive count.

Rehearse stages 1 to 5 end to end and record a screen capture as a fallback. A live demo
that fails in front of a security department costs more than the demo was worth.

## Distribution Plan

The airlock scripts cross the airlock themselves. Version them, checksum them, and record
the script version in every `verdict.json`, so a verdict can always be tied to the code that
produced it. Treat the first transfer of the scripts as a special case reviewed by hand. Who
owns updates to them once the process is live is an open question, below.

The presentation is the other deliverable: slides plus a recorded fallback of the demo.

## Open Questions

From the draft spec, still open:

- Does the security team accept role-based approval in GitLab CE, or does the target
  environment require Premium approval rules?
- Which findings block an import? The lab default above is provisional; the security team
  sets the real thresholds, particularly for Opengrep.
- What physical medium carries the transfer, and who carries it?

Raised during this session:

- **Does the customer already have a data diode, file transfer guard or full CDS, and is
  there any return channel at all?** Cheapest question on this list and the one most likely
  to invalidate a design decision. **The decisions it invalidates are `receipt.json` and the
  FAIL verdict's return path.** A data diode is one-way by construction: nothing comes back,
  so neither the receipt nor the rejection report can return as a file. Fallback if that is
  the case: the exporter keeps a **local ledger** of sent sequence numbers and treats
  unacknowledged bundles as pending, with both outcomes conveyed out of band, for example a
  message saying "seq 7 merged" or "seq 7 FAIL, commit abc123, `src/config.yml`, rule
  aws-access-key". The design works either way, but only if you know which one you are in
  before you build it.
- **Who operates the security station: your team or theirs?** Decides where the quarantine
  lives, who owns the scripts and who may change them, and whose name appears in the
  verdict.
- **At daily cadence, what is the agreed review SLA, and what happens when the reviewer is
  away?** Unanswered, this is what erodes the process in month three.
- **What database staleness is acceptable?** trivy rebuilds every six hours; the inside copy
  will always be older. Name an acceptable age and enforce it in the verdict.
- **Does the real repository use Git LFS or submodules?** Bundles carry neither. If yes, the
  transfer design needs a second channel for them.
- **What is the medium's capacity, against the measured baseline bundle size?** If the
  baseline does not fit, splitting and resume become a required follow-up.

## Success Criteria

- The lab runs on the PC and the setup steps are documented well enough for a second person
  to repeat them.
- All six acceptance scenarios in `docs/draftSpec.md` executed, with evidence attached:
  verdict files, merge request screenshots, SHA comparison. Those scenarios are: initial
  import of a clean repository; incremental update approved; update containing a secret
  blocked; removing the secret in a later commit still blocked; tampered or swapped bundle
  rejected; importer cannot bypass the review.
- **Scenario 7, offline scan.** After the mirror refresh and the worktree checkout, the
  three scanners run with the station container on `--network none` and produce the same
  verdict. Scoped to the scan phase deliberately: the customer forbids internet, not LAN,
  and GitLab lives on the LAN, so cutting the container off the network entirely would also
  cut it off from GitLab and would test the wrong constraint. The GitLab interaction is
  separately shown to make no outbound internet calls.
- **Scenario 8, replay refused.** An already accepted bundle is re-presented and station 2
  rejects it on the `airlock/seq/<n>` tag, and an out-of-order sequence number is likewise
  refused. Without this the sequence machinery is code with no acceptance test behind it.
- **Numbers measured and reported:** baseline bundle size in bytes (the single most useful
  input to the undecided medium question), round-trip time for one incremental update with
  reviewer time reported separately from machine time, and the false-positive count observed
  across the lab runs. The reviewer minutes and the false-positive count are the two numbers
  that decide whether this survives month three.
- **Limitations and follow-ups recorded in writing:** LFS, submodules, tags not entering
  GitLab, single-volume bundles, offline scanner updates, signing, and the deferred
  build-inside problem.
- Every open question above has a written answer or a named owner.
- The presentation is delivered and the security team's decision is recorded: adopt, adapt
  or reject.

## Dependencies

- **Customer-owned, for the deferred build-inside work:** internal Maven and npm
  repositories, installed and stocked. Named in the presentation with an owner.
- **Offline rule and database set:** trivy binary plus `trivy-db` and `trivy-java-db`,
  transferred and pinned as one set; Opengrep rules directory with its archive digest and
  source commit recorded; gitleaks TOML. The lab uses a copied directory; the `oras`
  registry mirror is the production route and is described on a slide, not built on the
  demo PC.
- Docker Desktop with the WSL2 memory ceiling raised, and a pinned GitLab CE version.
- The customer's decision on the transfer medium and on whether any return channel exists.

## The Assignment

Book 30 minutes with the person who will actually be the security reviewer. Not their
manager, not a mailing list. The person who will read the diffs.

Ask three questions and get the answers in writing:

1. What transfer medium do you accept, and do you already have a diode, guard or CDS we
   should be using? Is there **any** return channel, even a phone call? (If it is one-way
   only, both `receipt.json` and the FAIL report die, and the ledger fallback replaces
   them.)
2. Do you accept role-based approval in GitLab CE, where only your team holds Maintainer,
   or do you require Premium approval rules?
3. Who runs the scan: our team, or yours?

Then ask them to show you how they review and approve anything today, and watch without
helping. What they actually do will not match what they describe, and the gap is where your
workflow either fits or does not.

Those three answers are the only things that can invalidate this design. Each one costs a
week if you discover it during the demo instead of this week.
