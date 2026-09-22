# Build a lab to prove the controlled transfer of code updates from GitHub to local GitLab (Airlock PoC)
 
> **Type:** Task / Spike
> **Status:** draft v0.1
> **Last updated:** 2026-09-21
 
## Context
 
Development happens on GitHub. The target environment uses a local GitLab instance that cannot reach github.com. New code may enter GitLab only after the security team has evaluated and accepted it. Today there is no defined, repeatable way to move an update across this boundary, and no proof that what arrives in GitLab is exactly what left GitHub. This task sets up a laboratory on one Windows PC and proves a proposed process end to end, so the team can decide whether to adopt it.
 
## Goal
 
Demonstrate that the following three things all hold:
 
- A developer can export only the new commits from GitHub.
- The security team can verify and scan those commits outside GitLab.
- Only approved code reaches the protected branch in GitLab, with a commit SHA identical to the one on GitHub.
## Proposed approach
 
1. **Developer zone:** export everything since the last accepted commit as an incremental git bundle, with a manifest and a SHA-256 checksum.
2. **Security station:** a quarantine repository that is not GitLab. It does four things:
   - verifies the checksum;
   - checks that the bundle base equals the current GitLab `main`;
   - unpacks the bundle with git's object integrity checks (fsck) on;
   - scans the new commits with gitleaks (secrets), semgrep (static code analysis) and trivy (dependencies and misconfiguration).
   The result is a PASS or FAIL report.
3. **GitLab:** a bundle that passed is pushed as branch `incoming/<id>` with a merge request into protected `main`. A security reviewer reads the diff and merges it, fast-forward only.
4. **Confirmation:** compare the GitLab `main` SHA with the exported GitHub SHA and record it as the base for the next export.
## Scope
 
**In scope**
 
- GitLab CE running locally in Docker Desktop, reachable on localhost only.
- A lab project with two roles. The importer has the Developer role and cannot merge. The security reviewer has the Maintainer role and is the only one who can merge.
- Protected `main`: nobody can push, only Maintainers can merge, the merge method is fast-forward only, and force-push is off.
- The export, scan, import and confirm steps, run against one test repository on GitHub.
- The negative tests listed in the acceptance criteria.
**Out of scope**
 
- Production GitLab installation, backup, high availability, LDAP/SSO.
- Migration of GitHub issues, pull requests, wikis, releases.
- Git LFS objects and submodule contents, which a bundle does not carry. Record this as a limitation if the test repository uses them.
- An offline update routine for scanner rules and vulnerability databases. Record this as a follow-up.
- CI pipelines and runners in GitLab.
## Acceptance criteria
 
```gherkin
Feature: Controlled transfer of code from GitHub to local GitLab
 
Scenario: Initial import of a clean repository
  Given the GitLab project is empty
  And a full export of GitHub main has passed the security gate
  When the security reviewer pushes the baseline to main
  Then GitLab main has the same commit SHA as GitHub main
 
Scenario: Incremental update is approved
  Given GitLab main equals the last accepted GitHub commit
  And two new commits exist on GitHub main
  When the developer exports, the gate passes and the importer pushes the bundle
  Then the bundle contains only the two new commits
  And a merge request from incoming/<id> into main is open
  And GitLab main is unchanged until the security reviewer merges
  And after the merge GitLab main has the same SHA as GitHub main
 
Scenario: Update containing a secret is blocked
  Given a new commit on GitHub main contains an access key
  When the security station scans the bundle
  Then the verdict is FAIL and the report names the commit and file
  And the import step refuses to push the bundle to GitLab
 
Scenario: Removing the secret in a later commit is not enough
  Given the secret was removed by an additional commit on top
  When the new bundle is scanned
  Then the verdict is still FAIL because the secret remains in history
  And the verdict becomes PASS only after the unaccepted commits are rewritten
 
Scenario: Tampered or swapped bundle is rejected
  Given a bundle was modified after export, or replaced after it was scanned
  When it is scanned or imported
  Then the step fails with a checksum mismatch and nothing reaches GitLab
 
Scenario: Importer cannot bypass the review
  Given main is protected
  When the importer tries to push directly to main or to merge the merge request
  Then GitLab rejects the action
```
 
## Technical notes
 
- **Host setup:** GitLab has no native Windows installer, so it runs as a Docker container bound to 127.0.0.1. It needs about 4–6 GB of RAM and 5–10 minutes for the first boot. Pin the GitLab version.
- **Approval model:** required approval rules in merge requests are a GitLab Premium feature. In CE the equivalent control is role-based. Only the security team holds the Maintainer role, and only Maintainers can merge into `main`. The security team must confirm that this is acceptable.
- **Branch discipline:** nobody develops on GitLab `main`. It is a read-only record of approved GitHub states.
- **Scanner configuration:** changes to the scanner configuration files inside the repository (`.gitleaksignore`, `.semgrepignore`, `.trivyignore`) block the import. Changes to pipeline files, submodules and binaries are flagged for the human reviewer.
## Open questions
 
- Does the security team accept role-based approval in CE, or does the target environment require Premium approval rules?
- Which findings block an import? The proposal is any secret, plus dependency and misconfiguration findings that trivy rates HIGH or CRITICAL. The security team sets the blocking threshold for semgrep findings.
- How does the "last accepted commit" get back to the developer side in the real environment? Options are a receipt file or a tag on GitHub.
- What physical medium carries the transfer in the target environment, and who carries it?
## Definition of Done
 
- [ ] The lab is running on the PC and the setup steps are documented so that a second person can repeat them.
- [ ] All six acceptance scenarios have been executed and the evidence is attached: reports, merge request screenshots and the SHA comparison.
- [ ] Limitations and follow-ups are recorded: LFS, submodules, offline scanner updates.
- [ ] The results have been demonstrated to the security team and their decision is recorded: adopt, adapt or reject.