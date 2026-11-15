# frozen_string_literal: true

# Once a minute, read every GitHub credential's rate-limit budgets with `gh api rate_limit`
# and store them for GithubRateLimit, which uses the reading for two things:
#
#   - the reserve: an ordinary `gh` caller stands down when a budget is under
#     GithubRateLimit::RESERVE, so the trigger poller's preflight still has core budget
#     when the rest of Zimmer has spent it;
#   - the breaker: a budget GitHub reports as spent trips the breaker before any caller
#     is refused, so nothing spends a call to learn it.
#
# The probe is free. GitHub does not count `GET /rate_limit` against any budget, so this
# job costs a subprocess a minute per token and no budget at all.
#
# On `pollers` with the other GitHub-bound jobs. If that worker is down, the snapshot ages
# out after GithubRateLimit::SNAPSHOT_TTL and the reserve stops holding anyone back. That
# fails open: callers behave as they would without a reserve. The breaker still trips on
# the first refused call, because that path does its own probe.
class GithubRateLimitSnapshotJob < ApplicationJob
  queue_as :pollers
  include SingletonSweep

  def perform
    GithubRateLimit.credentials.each do |credential|
      next if GithubRateLimit.refresh(credential)

      # A host with no token at all (staging) reads through whatever `gh auth login` left,
      # which may be nothing. That is not news every minute, so it logs at INFO.
      level = credential[:id] == GithubRateLimit::AMBIENT_ID ? :info : :warn
      Rails.logger.public_send(level, "[GithubRateLimitSnapshotJob] Could not read GitHub's rate limits for " \
                                      "#{credential[:label]}; the reserve does not apply to it until the next reading")
    end
  end
end
