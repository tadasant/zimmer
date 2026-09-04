# Git Workflow Guide

This document describes the standard git workflow for this repository. It is the
shared reference the `open-pr` skill links to for branch naming, PR description format,
the session-scoped body-file rule, verification/proof standards, the `ready to merge`
label, and the ban on putting merge disposition in the PR body.

## Branch Naming Convention

Work on a feature branch, never directly on `main` (`main` is protected and lands
via PR). Prefix your branch with your GitHub username so it is easy to tell whose
work-in-progress a branch is:

```bash
<username>/feature-name
<username>/fix-bug-description
<username>/add-new-functionality
```

## Creating a Feature Branch

### Starting Fresh
```bash
# Ensure main is up to date
git checkout main
git pull origin main

# Create and checkout new feature branch
git checkout -b <username>/my-feature
```

### Recovering from Working on Wrong Branch

#### If on main
```bash
# Soft reset to preserve changes
git reset --soft origin/main

# Stash changes
git stash

# Create feature branch
git checkout -b <username>/my-feature

# Apply stashed changes
git stash pop
```

#### If on unrelated feature branch
```bash
# Reset to branch's remote state
git reset --soft origin/current-branch-name

# Stash changes
git stash

# Switch to main and update
git checkout main
git pull origin main

# Create new feature branch
git checkout -b <username>/my-feature

# Apply stashed changes
git stash pop
```

## Merged Branch Guard

**BEFORE pushing commits or updating a PR**, check if the current branch already has a merged PR:

```bash
gh pr view --json state --jq '.state' 2>/dev/null
```

If the state is `MERGED`:

1. Do NOT push to the merged branch — it will fail or create confusion
2. Fetch latest main: `git fetch origin main`
3. Create a new feature branch from the current HEAD: `git checkout -b <username>/<new-descriptive-name> origin/main`
4. Cherry-pick or rebase your working changes onto the new branch
5. Open a fresh PR from the new branch

If the command fails (no PR exists for this branch) or returns `OPEN`, proceed normally.

## Pre-Commit Checklist

Before committing and creating a PR, run these from the repo root:

1. **Lint** (RuboCop)
   ```bash
   bin/rubocop -a
   ```

2. **Security scan** (Brakeman)
   ```bash
   bin/brakeman
   ```

3. **Run targeted tests** — run the tests relevant to your change locally and let
   CI run the full suite
   ```bash
   bin/rails test test/models/session_test.rb
   ```

4. **Commit any lint fixes**
   ```bash
   git add .
   git commit -m "Apply RuboCop fixes"
   ```

## Creating a Pull Request

1. **Push your branch**
   ```bash
   git push origin <username>/my-feature
   ```

2. **Open PR via GitHub CLI**

   Author the body in a file **outside the working tree, at a path unique to your session**, and pass it with `--body-file`. Do NOT type a multi-line body inline with `--body "..."`, and do NOT use a fixed shared path like `/tmp/pr-body.md` — see [Never Share a Body-File Path](#never-share-a-body-file-path) below for the incident that rule comes from.
   ```bash
   echo "${AO_SESSION_SCRATCH_DIR:-$(mktemp -d)}/pr-body.md"   # write your body to the path this prints
   gh pr create --title "Description of changes" --body-file <that path>
   ```

   Inside Zimmer `$AO_SESSION_SCRATCH_DIR` is per-session and survives a restart; outside it, `mktemp`; never a fixed name. Print the path once and then use the literal it gives you: a harness that runs each command in a fresh shell loses the variable between calls, and a second `mktemp -d` is a different directory.

   `--body-file` passes your newlines through exactly as written and sidesteps the shell-quoting mangling that inline `--body "..."` invites when the prose contains quotes, backticks, or `$(...)`. If a file is inconvenient, use `--body "$(cat <that path>)"` rather than embedding the prose directly on the command line. Either way, how you *author* the body decides how it renders — see [Body Formatting: One Line Per Paragraph](#body-formatting-one-line-per-paragraph) below.

### Never Share a Body-File Path

**A fixed path like `/tmp/pr-body.md` is shared by every agent session on the box, so the file you wrote is not necessarily the file `gh` reads.** Zimmer runs many sessions concurrently on one host with one `/tmp`, and this document used to prescribe that exact path, so every session that followed it raced every other one.

On 2026-08-11 that race landed. One session wrote its own PR body to `/tmp/pr-body.md` while another was still working; **fifty seconds later** the second session re-read that same file to patch its own body, ran a substitution that silently matched nothing, and published the first session's description — a change to a different repository entirely — onto its own PR. The real description was destroyed, the command printed `BODY UPDATED`, and nobody noticed until a human read the merged PR. Both sessions were following this document exactly: the shared path is the root defect, and the silent read-modify-write in rule 3 below is what kept it from being caught.

Four rules, all cheap:

1. **Session-scoped path, always** — for any file you write outside the working tree, not just a PR body. An issue body, a PR or issue comment, a review body, a log, a PID file: `/tmp/issue.md` is as shared as `/tmp/pr-body.md` is, and a PID file is worse, because acting on a stale one kills another session's process. Use `"${AO_SESSION_SCRATCH_DIR:?}/…"` inside Zimmer and `mktemp` outside it; an empty `$AO_SESSION_SCRATCH_DIR` means you are **not** in a Zimmer session, and the fallback is `mktemp`, never a fixed name. The `:?` matters: an unset variable would otherwise expand to nothing and put the file at `/pr-body.md`, which is shared all over again — and while an ordinary user gets a permission error there, a container running as root does not. If your file-writing tool needs a literal absolute path and cannot expand a variable, resolve the directory once with `echo "$AO_SESSION_SCRATCH_DIR"` and write to the literal it prints — do not fall back to a fixed path because the variable was inconvenient.
2. **The body file is write-only from your side.** Never read back and patch a body file you wrote earlier. A session-scoped path narrows who can have overwritten it but does not close the question: two processes of one Zimmer session share one `$AO_SESSION_SCRATCH_DIR`, which has been observed happening ([tadasant/zimmer#395](https://github.com/tadasant/zimmer/issues/395)), and once a description has been edited at all, the copy on GitHub is the only authoritative one — your file is a draft that may predate an edit you or a reviewer made. To revise, either re-author the whole body, or refresh from the live PR first: `gh pr view <number> --repo <owner>/<repo> --json body -q .body > "${AO_SESSION_SCRATCH_DIR:?}/pr-body.md"`.
3. **A patch that finds nothing must fail loudly.** `str.replace`, `sed s///` and friends silently no-op when the anchor is absent — which is exactly what a clobbered file looks like — and then write the wrong content back over your PR. Assert the anchor is present before substituting (`assert old in s`), and treat a miss as a stop condition, not a warning.
4. **Pin the target and read it back.** Pass `--repo <owner>/<repo>` and the PR number explicitly on every `gh pr edit`, and confirm what actually landed rather than trusting the exit code: `gh pr view <number> --repo <owner>/<repo> --json body -q .body | head -3`. The first lines should be prose you recognise as this PR's.

### Body Formatting: One Line Per Paragraph

**Write each paragraph as a single unwrapped line. Do NOT hard-wrap prose or insert manual newlines mid-paragraph.** Separate paragraphs and list items with a blank line, and let each paragraph run long on one line.

GitHub renders PR, issue, and comment bodies with GitHub Flavored Markdown **hard line breaks**: a single newline *inside* a paragraph becomes a visible `<br>`, not a space. So prose wrapped at ~80 columns — the habit that feels natural when writing a code file or committing in an editor — renders as a column of early line breaks in the PR description. This is **not** a `gh` bug and no flag can undo it: `gh` passes `--body`/`--body-file` through verbatim, so the newlines you author are the newlines GitHub renders as breaks. Let each paragraph run long on one line; GitHub soft-wraps it for display on its own.

Good — renders as flowing paragraphs:
```
This change adds a reconciliation sweep so stranded sessions clear their marker. The sweep runs after the expiry pass, so already-unblocked sessions are skipped.

It is scoped to live sessions only.
```

Bad — renders with an early line break at every wrap point:
```
This change adds a reconciliation sweep so stranded sessions clear
their marker. The sweep runs after the expiry pass, so
already-unblocked sessions are skipped.
```

### PR Description Format

**This overrides the default Claude Code PR template.** Do NOT use a `## Test plan` section with unchecked checkboxes. Instead, use this format:

```
## Summary
<what changed and why>

## Verification
- [x] <what you actually did to verify, with proof>
- [x] <another verification step, with proof>
```

Every PR must demonstrate that changes work through **concrete evidence** — not assertions, not aspirations, not promises. The verification section is where the agent closes the loop between "I made changes" and "these changes work."

#### Closing Related Issues

If the PR resolves a GitHub issue, the description **must** include a closing keyword so the issue auto-closes when the PR merges. Leaving the keyword out means the issue stays open after merge and someone has to close it by hand — the single most common reason issues linger.

**Before opening the PR, do a quick pass through open issues** to find anything this work resolves. Don't rely on memory: you may be fixing a bug without realizing an issue already tracks it. Search, don't just recall:

```bash
gh issue list --state open --limit 100
gh issue list --state open --search "<keyword from the bug/feature you're addressing>"
```

When the PR resolves an issue, add a closing keyword referencing the **issue number** (not the PR number):

```
Closes #123
```

GitHub accepts `Closes`, `Fixes`, and `Resolves` (case-insensitive). To close multiple issues, **repeat the keyword for each** — GitHub does not parse a comma-separated list after a single keyword:

```
Closes #12, closes #34
```

Put the keyword in the `## Summary` section (or anywhere in the PR body). If the work relates to an issue but does not fully resolve it, reference it without a closing keyword (e.g. `Part of #56`) so it stays open.

#### Rules

1. **Use `## Verification`, not `## Test plan`** — "Test plan" implies aspirational work; "Verification" implies completed evidence.
2. **Every checkbox must be checked** — Unchecked boxes (`[ ]`) are never acceptable. They describe aspirational work that nobody will do. If you can't verify something, explain why instead of leaving an unchecked box.
3. **Every item must include proof** — A checked box without evidence is an assertion, not proof. "Tested it and it works" is not proof. What did you test? What happened? What did you see?
4. **UI changes MUST include screenshots** — No exceptions.

#### Proof Types

| Proof type | When to use | Example |
|---|---|---|
| **E2E test report** | Backend/logic changes | Describe what you tested end-to-end and what happened |
| **Screenshot** | UI changes (**required** — no exceptions) | Inline screenshot showing the result |
| **External confirmation** | Tasks with external side effects (API calls, emails, deploys) | Show the confirmation response or receipt |

E2E test reports are the most common type. Describe the scenario you exercised and what you observed — don't just say "it works."

**How agents capture and embed screenshots:**

1. **Capture** — Use a browser automation MCP server to take a screenshot of the page or component. Save it locally.
2. **Upload** — Use a remote filesystem MCP server to upload the screenshot, under a unique path prefix (e.g., `pr-<number>/screenshot-<name>.png`) so concurrent sessions cannot collide. The response carries a **signed** URL: the query string is the credential, and the link expires (14 days by default on this catalog's store).
3. **Embed** — Reference the URL the upload returned — not one you assembled from the object's path — in the PR description markdown: `![description](returned-url)`. Since it expires, also say in prose what the screenshot showed.
4. **Fetch it before you open the PR** — `curl -sS -o /dev/null -w '%{http_code}\n' "<url>"` must print `200`. Use a GET: the HTTP method is signed too, so `curl -I` fails on a perfectly good URL. A `403` is about the signature rather than the store — `AccessDenied` means the query string is missing or the link expired (mint a fresh one from the object's path), `SignatureDoesNotMatch` means characters were added or removed by a line wrap, emphasis around the URL, or truncation at the `?`.

If no remote filesystem MCP server is configured for the session, note in the PR description that screenshots were captured locally but could not be embedded, and describe what the screenshots show.

#### Always Include

Every PR should include these baseline verification items:

- `[x] CI green (all jobs pass)` — with specifics if helpful (e.g., "all jobs: brakeman, rubocop, tests")
- `[x] Self-reviewed PR diff — no unintended changes, no debug code`

#### Good Examples (with proof)

````
## Verification
- [x] E2E: Created a new session from an agent root, verified it transitioned waiting -> running
- [x] Screenshot of updated settings page:
  ![settings](https://github.com/user-attachments/assets/abc123)
- [x] Ran migration locally, verified column exists:
  ```sql
  SELECT column_name FROM information_schema.columns WHERE table_name = 'sessions';
  -- confirmed: new_column present
  ```
- [x] Sent test webhook, received 200 OK response:
  ```
  POST /webhooks/test -> 200 OK {"status": "received"}
  ```
- [x] CI green (all jobs pass)
- [x] Self-reviewed PR diff — no unintended changes, no debug code
````

#### Anti-Patterns (NEVER do this)

| Pattern | Why It's Bad |
|---------|-------------|
| `[ ] CI passes` | Unchecked box — aspirational, not verified |
| `[ ] Verify the session works end-to-end` | Unchecked box — nobody will do this |
| `[x] Tested it and it works` | Assertion without evidence — what did you test? what happened? |
| `[x] Verified the feature works correctly` | Says nothing — show what you did and what you saw |
| `[x] Added tests` | Incomplete — "Added tests" is not enough; "Ran tests and 11/11 passed" closes the loop |

#### The Closed Loop

The key insight is **reporting results, not just actions**:

- Bad: "Added tests" → What happened when you ran them?
- Good: "Added 3 tests in session_test.rb — ran locally, 3/3 pass"

- Bad: "Deployed to staging" → Did it work?
- Good: "Deployed to staging, verified the page loads and data appears correctly"

- Bad: "Fixed the bug" → How do you know?
- Good: "Reproduced the bug, applied fix, verified the error no longer occurs in logs"

#### The Reproduce-Fix-Verify Loop

For bug fixes, the standard verification pattern is **reproduce → fix → verify**:

1. **Reproduce** — Before writing any fix, first reproduce the bug. Confirm you can trigger the exact failure (error message, incorrect behavior, crash). This ensures you understand the problem and aren't fixing a symptom.
2. **Fix** — Apply the fix.
3. **Verify** — Reproduce the original steps again and confirm the bug is gone. Check that the fix didn't introduce regressions in related functionality.

This three-step loop is the most common form of closed-loop verification for bug fixes. The PR's `## Verification` section should document all three steps:

```
## Verification
- [x] Reproduced: triggered the 500 error by creating a session with a nil agent_type
- [x] Applied validation to reject nil agent_type at the model layer
- [x] Verified: same request now returns 422 with a clear error message
- [x] Ran related tests — 8/8 pass, no regressions
```

Skipping the reproduce step is a common mistake — if you can't reproduce the bug, you can't be confident your fix actually addresses it.

## Post-PR Workflow

### Immediately After Opening PR

1. **Self-Review First** (do NOT wait for CI)
   - Review the PR diff for code quality, correctness, and consistency
   - Address any issues found during review
   - Push fixes if needed

2. **CI Monitoring** (after review is complete)
   - Use the `wait-for-ci` skill to monitor CI progress
   - Fix any CI failures iteratively
   - Only consider the PR ready after CI is green

3. **Fresh-eyes review** — an independent subagent reviews the diff, and its findings are actioned before the label goes on

4. **Apply the `ready to merge` label** (the last action taken on the PR — see below)

5. **In Zimmer, sleep on the PR rather than parking on it** (see below) — the producing session schedules a bounded self-wake instead of coming to rest in the human's action queue

### The `ready to merge` Label

Every agent-authored PR ends by carrying the label `ready to merge`. The `open-pr` skill owns the step and spells out the exact mechanics; this section is the shared convention behind it, and what `wait-for-ci` and any repo-specific PR skill are deferring to.

The label is a **claim about the PR's state**, not a request for attention: the agent has self-reviewed it, a fresh-eyes subagent has reviewed it, every finding is addressed, and CI is green — so the only thing left is the merge. Never apply it to a red or half-finished PR. It is also the string the merge-side automation keys on, so treat it as an exact literal: three lowercase words, single spaces. `ready-to-merge` and `Ready to Merge` are different GitHub labels and will not fire anything.

**The label is orthogonal to merging and to human review.** Applying `ready to merge` does not merge the PR and does not assert a human has reviewed it — it only asserts the *agent-side* gate is complete: self-review, fresh-eyes subagent review, and green CI. That is exactly the end state of the `open-reviewed-green-pr` goal family ("open a reviewed, green PR; do NOT merge; leave it unmerged for the user"). So a goal that tells you to leave the PR unmerged for a human is **not** a licence to skip the label — the two are complementary, and the label is how the merge gate and a human skimming the list know the PR has cleared agent review. Two concrete ways this has gone wrong, both of which strand a green, reviewed PR unlabeled outside the merge pipeline: (a) using `wait-for-ci` to reach green and stopping there, never running the `open-pr` terminal step that owns the label — `wait-for-ci` deliberately hands the label off rather than applying it, so reaching green is not the same as finishing; and (b) knowing about the label and consciously withholding it "because the task said don't merge / leave it for the human." Apply the label once earned, *then* stop for the human.

Apply it as the **last action on the PR**, after CI is green and all review feedback is addressed. `gh pr edit --add-label` fails if the label does not exist in the repo, so create-if-missing first. Run both from the PR's branch; both are idempotent:

```bash
gh label create "ready to merge" --color 0E8A16 --description "Agent-authored PR: reviewed and CI-green; ready to merge" --force
gh pr edit --add-label "ready to merge"
```

`--force` updates an existing label in place instead of erroring (it overwrites that label's color and description). Adding a label the PR already carries is a no-op.

Two failure modes to handle rather than flail at:

- **No permission to label.** If the PR targets an upstream repo you don't own, `gh` resolves to that base repo and both commands 403. Skip the label and say so when you report the PR link.
- **You push again after labelling.** The label does not un-apply itself, so it would sit on a PR whose CI is re-running. Run `gh pr edit --remove-label "ready to merge"` before pushing the follow-up commit, and re-add it once CI is green again.

`wait-for-ci` intentionally does not apply the label — it hands the step back here — so repeated CI waits don't relabel. A repo-specific PR skill layered on top should run its extra steps *before* the label, keeping it terminal.

### After the Label: Sleep on the PR, Don't Park on It

**Zimmer only.** Applying the label is the last thing that happens *to the PR*, but in Zimmer it is not the last thing that happens in the *session*. Rather than coming to rest in `needs_input`, the producing session schedules a bounded `wake_me_up_later` self-wake and goes to `waiting`. It still holds the PR and still carries the work's context — it simply does not occupy a slot in the human's action queue while nothing yet needs a human.

The line this draws is the deployment's own line between a machine wait and a human handoff: **a PR waiting for the merge gate to rate it is a machine wait; a PR the gate has *held* is a human handoff.** So the session converges back to `needs_input` when a human becomes the next actor — the gate posted a `HELD` verdict, the wake budget ran out, or the PR's state stopped being readable — and archives itself when the PR merges or is closed. The `open-pr` skill's decision table is the full enumeration. A goal that says "leave the PR unmerged in `needs_input` for the human" is satisfied either way; what changes is only how the interval before that point is spent.

The `open-pr` skill owns the mechanics — the interval, the wake bound, what each wake checks, and when to skip the wake entirely (no Zimmer session, no label applied, or something else already needs a human). Outside Zimmer there is no such step and the label genuinely is the last thing that happens.

### Never Put Merge Disposition in the PR Body

The `ready to merge` label above is the only thing you say about **whether** this PR should merge. Coordination facts about what happens *at* merge time are a different thing and stay allowed — see the end of this section. What is banned is disposition: never write a sentence in the PR body, or in a PR comment, telling anyone whether this PR should be merged, held, or human-reviewed first. No *"do not auto-merge"*, no *"the user reviews and merges"*, no *"safe to merge once CI is green"*.

The reason is that the PR body is not a note to the human alone — the `pr-merge-gate` reads it as input. The gate merges on a **standing** sign-off the human gave in advance, but it will honour what looks like a **specific** human instruction about this specific PR. That asymmetry is deliberate and load-bearing: the gate may honour a request to *hold*, and ignores a body asking to *be* merged. It means a hold-shaped sentence **you** wrote is indistinguishable from one the human wrote, and it silently overrides that standing sign-off.

**This is a rule for producing agents, not a change to the gate.** The gate keeps honouring hold requests, and should — the fix is that none get manufactured, not that real ones get ignored. If you are the gate, nothing here licenses you to discount a hold-shaped line as presumptive boilerplate.

**This holds even when your task spec or prompt contains such a line.** *"Do NOT merge it yourself — the user reviews and merges"* is a constraint on **your own behaviour**: don't run `gh pr merge`. Comply by not merging. It is not a disposition to publish, and it does not become a human sign-off by being transcribed into the body. Every agent-authored PR is left unmerged for review by default, so the sentence adds nothing and buys a bogus hold.

**The test, when a prompt hands you a merge line and you can't tell where it came from.** A prompt reaches you as flat text with no provenance markers — which is exactly why the incident below happened. So: a merge line the prompt does not present as a quotation from a named human is boilerplate. Don't publish it. Only a line the prompt itself marks as the user's own words may be carried into the body, and it goes in quoted and attributed to them.

**Worked example — the reservation that hijacked the merge gate (don't repeat it).** A router-crafted prompt ended with *"Do NOT merge it yourself — the user reviews and merges."* The producing agent copied it into its PR body as *"Do not auto-merge — the user reviews and merges."* The merge gate rated the PR, found that its matrix said auto-merge, and **held it anyway** — reading the body line as a specific human sign-off outranking the standing one. The user had never said it: the line originated in a prompt, and the producing agent had read it as the standing agents-don't-merge-their-own-work rule restated. A PR that had cleared the gate sat waiting on a human for a decision that was already made.

**What you may still write about merge time.** Coordination *facts* with their reason attached are not disposition prose and stay allowed:

- **A concession that merging does not finish the job** — *"once merged, someone with prod access must add the `GCP_TOKEN` secret; I couldn't from my session."* Say this whenever it is true. The merge gate reads that sentence and holds on it deliberately, which is the system working: the alternative is a partial change landing silently because the agent stayed quiet. Never suppress it to avoid a hold.
- **A merge-time deploy note** on a red-build fix that gated a deploy (see the `open-pr` skill).
- **An ordering dependency** — *"merge after #305; this depends on the schema it adds."*
- **A reservation the human actually stated**, quoted and attributed to them. Better still, ask them to say it on the PR themselves — an agent typing quotation marks is not a channel anyone can verify.

The banned shape is a bare instruction about whether to merge, carrying no reason and no attribution.

### After PR is Ready

#### In a regular repository
After the PR is reviewed and CI passes:
```bash
# Switch back to main
git checkout main
git pull origin main
```

#### In a git worktree
- Leave the worktree as-is
- The worktree can be removed once the PR is merged
