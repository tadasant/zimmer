# Engineering Practices

Shared conventions for contributors working on Zimmer.

- **Runtime verification**: nothing merges to `main` until it has been proven to work at runtime.
  See [the section below](#prefer-fewer-features-that-are-proven-to-work).
- **Testing**: run targeted tests locally; delegate the full suite to CI.
- **Git workflow**: feature branches off the latest `main`; open a PR for review.
- **Code style**: follow the repository's linter (`standardrb` / RuboCop) defaults.

## Prefer fewer features that are proven to work

Prefer fewer features that are proven to work at runtime over more features that may or may not
work. If a feature or code path can't be runtime-verified, don't add it, and remove existing ones
that can't be verified. Never merge to `main` anything that hasn't been proven to work at runtime.

Code that has never run is a liability. Someone has to maintain it, it is exactly the "finished
confidently, and it doesn't run" failure the session goals exist to catch, and every unproven path
on `main` makes the proven ones harder to trust.

### What counts as proven

A code path is proven when it has run and been seen to do what it claims, before the merge:

- A test in CI that executes the path and asserts on the result. A test that stubs out the path it
  claims to cover proves the code around the stub, not the path.
- A run in development or on staging, with the evidence in the PR's `## Verification` section.
  Staging takes an unmerged branch (the `zimmer-deploy-staging` skill), which is the way to prove
  a change CI can't reach.

A careful read, a clean review, and a green lint job are not proof. The evidence a PR has to carry
is spelled out under "Verification" in `references/GIT_WORKFLOW.md`.

### When a path can't be verified

- **New code**: leave it out. A path for a platform no worker runs on, or for an integration
  nothing can exercise, waits until something can.
- **Code already on `main`**: the end state is removing it, in a PR scoped to that one path, not as
  a side effect of unrelated work. Until then it belongs on the
  [Known limitations](https://docs.zimmer.tadasant.com/limitations/) page marked as never
  runtime-verified, so nobody mistakes it for a working feature.

### Where this rule already shows up

- [Philosophy §3](https://docs.zimmer.tadasant.com/intro/philosophy/#3-closed-loop-autonomy-done-means-verified):
  "done" means verified, which is why a session's goal makes it prove its work before it comes back.
- [Philosophy §9](https://docs.zimmer.tadasant.com/intro/philosophy/#9-the-pull-request-is-the-review-gate):
  the agent's job ends at "open a PR and prove it's green."
- [Philosophy §10](https://docs.zimmer.tadasant.com/intro/philosophy/#10-be-honest-about-whats-broken)
  and the Known limitations page: an unverified path is written down, not hidden.
- [Testing](https://docs.zimmer.tadasant.com/operate/testing/): the suite has no end-to-end coverage
  of spawning a real agent, so a change to that path is proven by running it.
