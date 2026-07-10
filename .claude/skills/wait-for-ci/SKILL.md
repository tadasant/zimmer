---
name: wait-for-ci
description: >
  Block until CI passes or fails on the current PR. Use this skill every time
  you push a commit and intend to tell the user the work is done — never
  present a pushed commit as complete without first confirming CI is green.
  Also use it when waiting on CI before merging, deploying, or moving on to
  the next task in a multi-step plan.
user-invocable: true
---

# Wait for CI

## Sequencing Checklist

- [ ] Verify prerequisites (`gh auth status`, branch has an open PR)
- [ ] Run `gh pr checks --watch --fail-fast`
- [ ] If no checks reported, wait 30s and retry (up to 2 retries)
- [ ] If still no checks, diagnose (merge conflicts, no matching workflows, GitHub outage)
- [ ] If CI fails, read failing check logs (`gh run view <run-id> --log-failed`) and fix
- [ ] Report result: CI passed, CI failed (with details), or no checks expected

Block until all GitHub Actions CI checks pass or fail on the current PR.

## Prerequisites

**IMPORTANT: Check every prerequisite below BEFORE doing any work. If any check fails, stop immediately, tell the user which prerequisite is not met, and ask them to fix it. Do NOT proceed, improvise, or attempt workarounds.**

- The `gh` CLI must be installed and authenticated (`gh auth status` must succeed)
- You must be on a branch with an open PR (`gh pr view` must succeed)

## Usage

Run this single blocking command:

```bash
gh pr checks --watch --fail-fast
```

- Blocks until all checks complete
- Exits 0 if all checks pass
- Exits non-zero and stops early (`--fail-fast`) if any check fails

## When no checks are reported

If `gh pr checks` returns immediately with "no checks reported", CI hasn't started yet. Wait briefly and retry:

```bash
sleep 30 && gh pr checks --watch --fail-fast
```

If after 2 retries (~1 minute) there are still no checks, diagnose:

1. **Merge conflicts** — resolve them, push, then retry the wait.
2. **No matching workflow triggers** — confirm the repo's `.github/workflows/` files actually trigger on this PR's conditions (`push`, `pull_request`, path filters, etc.). If nothing should trigger, CI can be considered green.
3. **GitHub outage** — check https://www.githubstatus.com. If GitHub Actions is degraded, let the user know and bail out.

## Integrating into your workflow

This skill is designed to be invoked after pushing commits to a PR, so that Claude can block and wait for the result before proceeding. Typical sequence:

1. Make changes and commit
2. Push to the PR branch
3. Invoke `/wait-for-ci`
4. If CI passes, continue with next steps (e.g. merge, deploy)
5. If CI fails, read the failing check logs with `gh run view <run-id> --log-failed` and fix
