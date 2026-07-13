# Git Workflow Guide

This document describes the standard git workflow for this repository. It is the
shared reference the `pr` skill links to for branch naming, PR description format,
and verification/proof standards.

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

   Author the body in a file (use a temp path like `/tmp/pr-body.md` so a stray file never lands in the working tree) and pass it with `--body-file`. Do NOT type a multi-line body inline with `--body "..."`.
   ```bash
   gh pr create --title "Description of changes" --body-file /tmp/pr-body.md
   ```

   `--body-file` passes your newlines through exactly as written and sidesteps the shell-quoting mangling that inline `--body "..."` invites when the prose contains quotes, backticks, or `$(...)`. If a file is inconvenient, use `--body "$(cat /tmp/pr-body.md)"` rather than embedding the prose directly on the command line. Either way, how you *author* the body decides how it renders — see [Body Formatting: One Line Per Paragraph](#body-formatting-one-line-per-paragraph) below.

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
2. **Upload** — Use a remote filesystem MCP server to upload the screenshot. Request public access on upload and use a unique path prefix (e.g., `pr-<number>/screenshot-<name>.png`) to avoid collisions. The upload response includes a public URL.
3. **Embed** — Reference the returned public URL in the PR description markdown: `![description](returned-url)`.

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
