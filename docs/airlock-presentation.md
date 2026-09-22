# Airlock: GitHub to internal GitLab — presentation

Source of truth for the deck published at
<https://claude.ai/artifact/7C1xcnsDJSN7pWBm6ggTBq> (private; share from the page's share
menu, or download as PDF or PowerPoint from there).

- **Audience:** the customer's security department, plus their project side.
- **Purpose:** get a decision on the transfer process. Adopt, adapt or reject.
- **Length:** 15 slides, roughly 20 minutes plus questions.
- **Based on:** [`designs/github-to-gitlab-airlock.md`](designs/github-to-gitlab-airlock.md)
  and [`draftSpec.md`](draftSpec.md).

**Before presenting:** replace the cover date and the two illustrative commit SHAs (slides
4 and 9) with real values from your own lab run. A real SHA from the actual repository is
more convincing than a plausible-looking one.

## Design

| | |
|---|---|
| Headings and body | IBM Plex Sans (400/500/600/700) |
| SHAs, verdicts, file names | JetBrains Mono (400/500/600) |
| Type scale | 140 / 64 / 40 / 28 / 24 px on a 1920×1080 canvas |
| Ink (dark) | `#14202E` |
| Paper (light) | `#F7F7F4` |
| Card fill | `#ECEDE8`, border `#D8D9D2` |
| Body text on light | `#4A5563` |
| PASS / safe | `#2B6E62` (`#6FBFA8` on dark) |
| FAIL / blocked | `#A8432F` |

Three backgrounds only: light for the body of the deck, dark for the cover and the
closing, and the green as a single statement slide (4). Colour never carries meaning
alone; every PASS and FAIL is also a word.

---

## 1. Cover

**Airlock**

A controlled, auditable way to move approved code from our GitHub into your internal
GitLab. Weekly, or daily, for the life of the contract.

*Eyebrow:* Proposal for the security department
*Footer:* 21 September 2026 · Draft for discussion — Decision needed: adopt, adapt or reject

> **Notes.** Open by naming the decision. We are not asking for permission to develop
> outside the network; that is already agreed. We are asking whether this specific process
> is acceptable as the way code enters GitLab. Twenty minutes, then questions.

---

## 2. The ask — Is this an acceptable way for code to enter your GitLab?

Development outside your network is already agreed. What is not agreed is the process.
This is that process, end to end, so you can judge it as a whole rather than in pieces.

- **Adopt** — Use it as proposed. We build it properly and run the first real transfer.
- **Adapt** — Tell us what to change. Most of this is negotiable. The three questions at
  the end move it the most.
- **Reject** — Tell us why. We would rather know today than after we have built it.

> **Notes.** Say plainly that a reject today is cheaper than a reject in two months. It
> lowers the cost of them being honest.

---

## 3. Where we are today

- **Unchanged — your requirement stands.** Final builds and tests run inside your network,
  with no internet access. Nothing in this proposal asks you to relax that.
- **Agreed — development happens outside.** Updates arrive as bundles that your security
  team reviews before anything is merged. That concession is already made.
- **Missing — the process itself.** No defined way to move an update, and no evidence that
  what arrives inside is what left, unchanged. That is the gap.

Without a defined process, every transfer is negotiated from scratch and nobody can show
afterwards what was approved. With one, each transfer leaves the same three files behind as
its record.

> **Notes.** Do not relitigate the concession here. One sentence, then move on. The room's
> attention belongs to the third card.

---

## 4. The property everything rests on *(statement slide)*

**After every transfer, your main and our main carry the same commit SHA.**

Git is content addressed, so an identical SHA means identical history, byte for byte, all
the way back to the first commit. Two settings guarantee it: the gate refuses any bundle
that does not continue from your current main, and main merges fast-forward only, so no
merge commit is ever created.

```
github  main  4a3c6a8a3cad82cfffdaa4d1
gitlab  main  4a3c6a8a3cad82cfffdaa4d1
```

> **Notes.** This is the slide to slow down on. Everything later is machinery that protects
> this one claim. If they accept nothing else, they should leave remembering that the two
> sides are provably identical rather than merely similar.

---

## 5. Four stations, every time

| | Zone | Station | What happens |
|---|---|---|---|
| 1 | Our side | **Export** | Everything on main since your last accepted commit, as one git bundle with a manifest and a checksum. |
| 2 | The gate | **Quarantine** | Not GitLab. Verify, unpack, scan. The result is a PASS or FAIL verdict tied to those exact bytes. |
| 3 | Your GitLab | **Merge** | A passed bundle opens a merge request into protected main. Only your team can merge it. |
| 4 | Your GitLab | **Confirm** | Compare the merged SHA, write the receipt, and that becomes the base for the next transfer. |

Nothing reaches GitLab until the gate says PASS **and** one of your Maintainers has read the
diff and merged it. The gate can only refuse; it can never approve on your behalf.

> **Notes.** Walk the four boxes left to right, thirty seconds each. The sentence underneath
> is the one that matters to this room: the automation can only block, never admit.

---

## 6. Station 1 — What leaves our side

**In the bundle**

- Only the branch main, plus any tags named explicitly in the manifest.
- Only the commits made since your last accepted one, not the whole repository.
- A manifest listing every commit and every reference it contains, and how large it is.
- A SHA-256 of the bundle file.

**Never in the bundle**

- Feature branches. Station 3 merges main only, so anything else would land unread.
- Any other reference namespace. The gate accepts two and rejects the rest by name.
- Large files and submodule contents, which a bundle cannot carry. A known limitation,
  listed at the end.

Before we build anything, we check that your last accepted commit is still in our history.
If someone has rewritten it, we stop and come to you rather than send a bundle that cannot
merge.

> **Notes.** The last line is the honest one. Rewritten history is the failure this design
> cannot absorb quietly, so we surface it as a conversation rather than a broken import.

---

## 7. Station 2 — What the gate checks, in order

**First, before anything is read**

1. The checksum matches the manifest.
2. The bundle continues from your current main, and nothing else.
3. Git verifies the bundle, and every object is checked for damage as it is unpacked.
4. Only main and named tags are accepted. Every other namespace is refused, including the
   one that can change what a diff shows you.
5. Every reference the manifest promised is there, and nothing extra.
6. The sequence number is the next one, and has not been used before.

**Then the scanners**

- **gitleaks**, across the new commit range. Finds secrets anywhere in the new history, not
  only in the current files.
- **Opengrep**, across the new tree. Finds dangerous code patterns.
- **trivy**, across the new tree. Finds vulnerable dependencies and misconfiguration.
- All three run with no network access at all. Their rules and databases are transferred in
  and pinned, and their age is recorded in the verdict.
- **Every scanner reads its configuration from the gate, never from the incoming
  repository.**

That last line is the control. A repository that ships its own ignore file, or an inline
comment telling a scanner to look away, changes nothing here. Those edits are themselves
treated as blocking changes and shown to the reviewer.

> **Notes.** Expect the question "how do we know the scanners were really run offline".
> Answer: we demonstrate it with the network switched off, and the verdict records each
> tool version and database age.

---

## 8. Station 3 — Who can do what, inside your GitLab

| Action | Us, the importer | You, the reviewer |
|---|---|---|
| Role held in GitLab | Developer | Maintainer |
| Push an incoming branch | Yes | Yes |
| Push directly to main | No | No, nobody can |
| Merge into main | No | Yes, only you |
| Force push or rewrite main | No | No, disabled |
| Change the scanner rules | No | Yes |

GitLab Community Edition has no approval rules; those are a paid feature. The equivalent
control here is the role itself: only your team holds Maintainer, and only a Maintainer can
merge. Merges are fast-forward only, so the merged history is identical to what was
scanned. **We need you to confirm this substitution is acceptable.**

> **Notes.** This is the first of the three questions. If they require Premium approval
> rules, that is a licensing decision on their side and it changes the timeline, not the
> design.

---

## 9. Station 4 — The proof, and the receipt

**After the merge.** The merged SHA is compared against the one the manifest declared when
the bundle was built. They match, or the transfer is not complete. In the demonstration we
also put our GitHub screen beside yours, so the match is something you see rather than
something we assert.

**Then the receipt.** A short record of what was accepted and in what order. It comes back
to us and becomes the base for the next transfer. If nothing at all may travel back out,
the receipt becomes a message instead of a file. That is one of the three questions we have
for you.

```
seq 7   accepted   4a3c6a8a3cad82cfffdaa4d1   base for seq 8
```

> **Notes.** The receipt also makes replay detectable: a bundle presented twice, or out of
> order, is refused at the gate because its sequence is already recorded inside.

---

## 10. Every transfer leaves three files behind

Plain text, readable by a person, kept beside each other. This is the audit trail, and it is
the only part of this proposal we are building ourselves.

- **`manifest`** — What we say we are sending: the commit range, every reference, the size,
  the checksum, who exported it and when. *Written outside.*
- **`verdict`** — What was actually checked: every tool and version, every database and its
  age, every finding, PASS or FAIL, and the checksum of the exact bytes it refers to.
  *Written inside, by the gate.*
- **`receipt`** — What was accepted, and in what order. Closes one transfer and opens the
  next. *Written inside, after the merge.*

Because the verdict names the checksum rather than a filename, it is tied to one specific
bundle. A different file with the same name cannot inherit its approval.

> **Notes.** If they ask what happens to these files long term: they live beside the
> repository inside, and they are the answer to "who approved this commit, when, and
> against which rules".

---

## 11. Where this is weak — What the checksum proves, and what it does not

**It does prove**

- The bundle was not damaged on the way in.
- The file that was merged is the same file that was scanned. The verdict is written inside
  your boundary and names that checksum, so a bundle cannot be exchanged for another
  between the scan and the import.

**It does not prove**

- That nobody altered the bundle in transit. The checksum travels on the same medium as the
  bundle, so anyone able to replace one can replace the other.
- Who exported it. The names in the manifest are labels, not signatures.

**The fix is known and small:** either send the checksum by a second route, or sign the
bundle with a key you already hold. We have not built it, because it should be built against
whatever medium you choose rather than the one we guessed.

> **Notes.** Put this slide in deliberately and early in the questions. A security team will
> find this gap within five minutes; reaching it first is worth more than the gap costs.

---

## 12. A secret gets committed. What happens.

- **FAIL** — A developer commits an access key by mistake. The gate refuses the bundle and
  the verdict names the commit, the file and the rule that caught it. Nothing is pushed to
  GitLab.
- **FAIL** — The developer deletes the key and commits again. **Still refused.** Deleting a
  file does not remove it from history, and a bundle carries the history. This is the case
  most processes miss.
- **PASS** — Only once the unapproved commits have been rewritten on our side, so the key is
  genuinely gone, does the bundle pass. The key itself is treated as compromised and rotated
  regardless.

The rewrite is limited to commits you have not yet accepted. History you have already
approved is never rewritten, because that would break the guarantee on the earlier slide.

> **Notes.** Demonstrate all three beats live. The second one is what convinces a security
> audience that the process was designed by someone who understands git rather than someone
> who installed a scanner.

---

## 13. What this costs your team, honestly

Weekly at first, possibly daily. Per transfer, one of your Maintainers does three things.

- **Read one diff** — covering only the new commits, with the gate's findings already
  attached.
- **Merge, or refuse** — one click either way. Nothing else in the chain can do it for you.
- **Send back a line** — if refused, we need the verdict back, or we cannot know what to fix.

**We will measure three numbers and show you, before you commit to anything.** Minutes of
reviewer time per transfer. False alarms per week. Total time from our commit to your merge.
At daily cadence, the first two decide whether this process survives its third month, and we
would rather size that with you now than discover it later.

> **Notes.** Do not soften this. Naming the burden yourself is what makes the rest of the
> deck credible, and it opens the conversation about an agreed review window and a named
> deputy.

---

## 14. What this proposal does not cover

Four things, each with an owner. None of them is hidden, and none of them is solved by this
process alone.

| | | Owner |
|---|---|---|
| **Building and testing inside** | Needs your internal Maven and npm repositories installed and stocked. Source crosses the boundary; dependencies do not. | Your platform team |
| **Pipelines and runners in GitLab** | This process ends when approved code is in GitLab. Nothing here executes it. | A separate conversation |
| **Keeping the scanners current** | Rules and vulnerability databases age. Refreshing them inside is a second, smaller transfer on the same principle. | Designed, not built |
| **Signed bundles and verdicts** | Closes the transit gap shown earlier. | The first thing we build if you say yes, against the medium you choose |

> **Notes.** Large files and submodule contents are the fifth limitation; mention them only
> if their repository actually uses either.

---

## 15. Three answers, and a decision

1. What medium do you accept for the transfer, and is there **any** route back, even a phone
   call? If nothing can return, the receipt and the rejection report both become messages
   rather than files.
2. Do you accept role-based approval, where only your team holds Maintainer, or do you
   require the paid approval rules?
3. Who operates the gate and runs the scanners: us, or you? This decides where it lives and
   whose name is on each verdict.

Those three are the only answers that can change this design. Everything else we can build
against what is on these slides. **Adopt, adapt or reject, and we will take it from there.**

> **Notes.** Ask for the answers in writing, and ask for thirty minutes with whoever will
> actually read the diffs. Watching them review something they already own tells you more
> than any answer on this slide.
