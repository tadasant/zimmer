# frozen_string_literal: true

# GitHub CLI Token Initializer
#
# Publishes the `gh` CLI's token (GH_TOKEN) into the process environment at boot,
# resolved through the `${VAR}` chain — Parameter Store first, then encrypted
# credentials, then whatever ENV already held.
#
# This makes GitHub auth a property of the container rather than of whether a poll
# tick has run yet: the first `git clone` of the first session authenticates, without
# waiting on GithubTriggerPollerJob. GithubSearchService.configured? re-runs the same
# (idempotent) provisioning on every poll tick — clocked to at most one chain read per
# GhTokenProvisioner::REFRESH_INTERVAL — which is what keeps a rotated token current in
# a long-lived worker.
#
# A no-op wherever no token is configured (dev, test, CI, a fork that never set one),
# and never fatal: GhTokenProvisioner.ensure! swallows and logs.
Rails.application.config.after_initialize do
  next if Rails.env.test?

  GhTokenProvisioner.ensure!
end
