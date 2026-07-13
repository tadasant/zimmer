---
name: pr
description: >
  Push working state to a PR — commit all changes, push to branch, open PR,
  self-review, subagent review, and wait for CI. Generic workflow usable
  across all repos.
disable-model-invocation: true
---

# Push Working State to a PR

Take the current git diff (ALL files), commit, push to a feature branch, open a PR, verify CI, and surface the PR link.

For git conventions (branch naming, PR description format, verification/proof standards, wrong-branch recovery), see [references/GIT_WORKFLOW.md](references/GIT_WORKFLOW.md).

## Common Pitfalls

Read these before starting the checklist — every one has bitten agents in practice. Most result in wasted work, noisy reverts, or handing back an unfinished PR.

### Don't push to an already-merged PR

**Before pushing or updating a PR**, confirm the current branch's PR isn't already merged:

```bash
gh pr view --json state --jq '.state' 2>/dev/null
```

If the command returns `MERGED`, do NOT push. The merged PR has been closed and pushing to its branch will either error out or produce commits nobody will review. Open a fresh feature branch from latest `main` and PR your changes from there. See the [Merged Branch Guard](references/GIT_WORKFLOW.md#merged-branch-guard) section of GIT_WORKFLOW.md for the full recovery procedure.

If the command fails (no PR for this branch) or returns `OPEN`, proceed normally.

### Don't hand back before CI is green

A pushed commit is not a finished commit. After pushing, block on CI before telling the user the work is done:

```bash
gh pr checks --watch --fail-fast
```

Or invoke the `wait-for-ci` skill. If CI fails, fix it and push again — never declare success and leave the red check for the user to find. See the [CI Fix Loop](#ci-fix-loop) section below for the iterate-until-green procedure.

### Don't commit without checking `git status`

Build steps, linters, `npm version`, schema dumps, and auto-formatters routinely modify files you didn't touch by hand. Missing one is a common cause of CI failures that could have been caught in seconds. Before committing, and again after:

1. `git status` — any unstaged changes?
2. `git diff --cached` — is the staged diff actually what you meant to commit?
3. After committing, `git status` again — is the working tree clean?

See [Common Scenarios That Cause Missed Files](#common-scenarios-that-cause-missed-files) below for the usual suspects.

### Don't hard-wrap the PR body

Write each paragraph of the PR body as a **single unwrapped line** — no manual newlines mid-paragraph — and separate paragraphs with a blank line. GitHub renders PR bodies with hard line breaks, so prose wrapped at ~80 columns shows up as a column of early line breaks in the description. Author the body in a file and pass it with `gh pr create --body-file <file>` so your newlines survive verbatim. See [Body Formatting: One Line Per Paragraph](references/GIT_WORKFLOW.md#body-formatting-one-line-per-paragraph) in GIT_WORKFLOW.md for the why and worked examples.

### Don't force-push carelessly

When a rebase or amend requires a force-push, always use `git push --force-with-lease` — it refuses to overwrite remote commits you haven't seen, so you can't silently clobber a collaborator's work. Never force-push to `main` or other shared/long-lived branches; force-pushing is only acceptable on your own short-lived feature branch.

## Sequencing Checklist

- [ ] **Merged branch guard**: Check if current branch's PR is already merged (per GIT_WORKFLOW.md)
- [ ] If on wrong branch, recover per GIT_WORKFLOW.md
- [ ] **CRITICAL**: Run `git status` and verify ALL modified files are included
- [ ] Run `git diff --cached` to review exactly what will be committed
- [ ] If you see "Changes not staged for commit", run `git add .` then `git status` again
- [ ] Commit the changes with a descriptive message
- [ ] **AFTER COMMITTING**: Run `git status` to ensure working tree is clean
- [ ] Push to feature branch
- [ ] **Scan open issues for anything this work closes** (see Closing Related Issues below). Don't rely on memory — you may be fixing a bug an existing issue already tracks
- [ ] Open a PR (or update existing one). Write PR description per GIT_WORKFLOW.md format — one line per paragraph, no hard wraps, passed via `--body-file` (see Common Pitfalls above) — including a `Closes #<issue-number>` keyword for any issue this PR resolves
- [ ] If the change is UI-visible, capture and embed screenshots (see Embedding Screenshots below)
- [ ] Check for merge conflicts; if present, resolve them (see Merge Conflicts below)
- [ ] Perform self-code review of the PR diff
- [ ] Action any issues found during self-review
- [ ] Launch a subagent to perform a thorough PR review with fresh eyes (see below)
- [ ] Action critical and warning issues from the subagent review. Push fixes if needed
- [ ] Ensure CI is green (see CI Fix Loop below)
- [ ] Think about what you learned during this PR process. Add any useful insights to the "Claude Learnings" section in the appropriate CLAUDE.md file
- [ ] Surface the PR link back to the user

## Common Scenarios That Cause Missed Files

Watch for these — they modify files that are easy to forget to stage:

- Running `npm version` or `npm run stage-publish` (modifies package.json, package-lock.json, creates git tags)
- Build processes that modify generated files
- Auto-formatting that changes multiple files
- Dependency updates that modify lock files

## Closing Related Issues

Before opening the PR, do a quick pass through open GitHub issues to find anything this work resolves, then include a closing keyword in the PR description so the issue auto-closes on merge. This is the most common reason issues are left open after a merge.

**Search — don't rely on memory.** You may be fixing a bug without realizing an issue already tracks it, so search by keyword in addition to scanning the list:

```bash
gh issue list --state open --limit 100
gh issue list --state open --search "<keyword from the bug/feature you're addressing>"
```

For any issue this PR resolves, add a closing keyword referencing the **issue number** (not the PR number) — e.g. `Closes #123`. For multiple issues, repeat the keyword (`Closes #12, closes #34`). See the [Closing Related Issues](references/GIT_WORKFLOW.md#closing-related-issues) section of GIT_WORKFLOW.md for the exact keyword rules and where to place them.

## Merge Conflicts

When merge conflicts are detected (CI reports them, or `git pull --rebase origin main` produces them):

1. **BEFORE STARTING**: Run `git status` to see current state
2. Analyze the commit(s) that introduced the merge conflicts so you understand their intent
3. Initiate a git rebase on `main` with `git pull --rebase origin main`
4. Go file-by-file as conflicts occur, assessing what the right merging is that still accomplishes the intent of both your PR and the conflicting commits
5. **AFTER RESOLVING EACH CONFLICT**: Run `git status` to see remaining conflicts
6. **BEFORE CONTINUING REBASE**: Run `git add .` to stage all resolved conflicts
7. Continue the rebase with `git rebase --continue`
8. **AFTER REBASE COMPLETE**: Run `git status` to ensure working tree is clean
9. Force-push to update the PR branch: `git push --force-with-lease`

## Self-Code Review

Before waiting for CI, perform a self-code review of your PR diff:

1. Review the diff on GitHub or via `gh pr diff`
2. Look for:
   - Logic errors or bugs
   - Missing edge cases
   - Code style issues
   - Unnecessary changes or debug code
   - Security concerns
3. Fix any issues found and push the fixes

## Subagent PR Review

After completing your self-review, launch a subagent to perform an independent code review with fresh eyes. This happens **before** waiting for CI — while CI runs on GitHub in the background, you perform the review locally, making efficient use of the wait time. The subagent reviews the same categories as your self-review but with fresh context, which helps catch issues that are easy to miss when you wrote the code yourself.

Use your runtime's in-process subagent (the `Task` / `Agent` tool with `subagent_type: "general-purpose"` in Claude Code, `spawn_agent` in Codex) and a prompt like:

> Review the PR diff for this branch. Run `gh pr diff` to see the changes. Look for:
>
> - Logic errors, bugs, or incorrect behavior
> - Missing edge cases or error handling
> - Security concerns (injection, XSS, credential exposure, etc.)
> - Violations of patterns and conventions in the codebase (check CLAUDE.md)
> - Unnecessary changes, dead code, or debug artifacts
> - Test coverage gaps for the changes made
> - Documentation that needs updating
>
> For each issue found, provide the file path, line number, severity (critical/warning/nit), and a clear description of the problem and suggested fix.

Action all critical and warning issues from the subagent review. Use your judgment on nit-level issues — fix quick ones but don't block the PR on them. Push fixes if any changes were made.

## Embedding Screenshots

When the PR includes UI-visible changes, screenshots are **required** in the `## Verification` section. Follow the capture-upload-embed procedure documented in [references/GIT_WORKFLOW.md](references/GIT_WORKFLOW.md):

1. Capture screenshots using a browser automation MCP server
2. Upload via a remote filesystem MCP server (request public access, use a unique path prefix)
3. Embed the returned public URL in the PR description markdown

If no remote filesystem MCP server is available, note that screenshots were captured locally but could not be embedded, and describe what they show.

## CI Fix Loop

After completing the subagent review (and actioning any issues), ensure CI is green before handing back to the user.

1. Run `gh pr checks --watch --fail-fast` to block until all checks complete
2. If no checks are reported, wait 30s and retry (up to 2 retries). If still no checks, diagnose: merge conflicts, no matching workflows, or GitHub outage (check https://www.githubstatus.com)
3. If all checks pass, CI is green — done
4. If any checks fail:
   - View failure logs with `gh run view <run-id> --log-failed`
   - Fix the issues locally
   - **CRITICAL**: Run `git status` to see all modified files from the fix
   - **CRITICAL**: Run `git add .` to stage all changes
   - **CRITICAL**: Run `git status` again to verify working tree is clean
   - Commit and push the fixes
   - Go back to step 1
5. Repeat until all checks pass
