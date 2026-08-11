# frozen_string_literal: true

# Materializes the `gh` CLI's GitHub token into the process environment, sourced
# from the `${VAR}` chain (Parameter Store → encrypted credentials → ENV).
#
# ## Why the environment, and not `gh auth login`
#
# Four different callers need GitHub auth, and only one of them is ours to pass an
# env hash to:
#
#   - GithubSearchService shells out to `gh api search/issues`, gated on
#     `gh auth status` — the GithubTriggerPollerJob path.
#   - GitCloneService runs `git clone`, and Dockerfile.base wires git's credential
#     helper to `gh auth git-credential`. Git spawns that helper itself, so the only
#     way to reach it is an inherited environment.
#   - The other GitHub pollers (comments, PR status, merge conflicts) shell out to
#     bare `gh` with no env hash.
#   - Spawned agent sessions run `gh` themselves, inheriting the worker's ENV.
#
# `gh` reads GH_TOKEN straight from its environment, so one variable authenticates
# all four. An interactive `gh auth login` would authenticate them too, but it does
# not survive container recreation — and staging is rebuilt from scratch on every
# deploy.
#
# ## Why the chain, and not a deploy-time env var
#
# Putting the token in `env.secret` would mean storing it as a GitHub Actions secret:
# a GitHub credential, held by GitHub, to talk to GitHub. Reading it from the store
# instead keeps the value in Google Parameter Manager, where it is rotated with one
# `gcloud secrets versions add` and picked up within REFRESH_INTERVAL plus the store's
# own snapshot TTL — no redeploy, and no second copy in a CI secret store.
#
# The chain is what makes that a non-event everywhere else: with no store configured
# the value simply comes from encrypted credentials or ENV, exactly as any other
# `${VAR}` does, so dev, test, and a fork that never set it are unaffected.
#
# ## The one staleness this accepts
#
# ENV is both an output of this class and the chain's last link. If a token is
# resolved from the store and later DELETED from it, the chain falls through to the
# ENV entry this class wrote and keeps serving it until the process restarts. That is
# the deliberate trade for letting a plain `GH_TOKEN=…` keep working in dev and for a
# self-hoster: a delete is not a rotation, and a rotation (a new version at the same
# path) propagates normally.
class GhTokenProvisioner
  # The `${VAR}` name, which is also the environment variable `gh` reads. Its
  # canonical store path is ParameterStore::Namespace.parameter_path("GH_TOKEN") —
  # /zimmer/{env}/mcp/static/GH_TOKEN.
  VARIABLE = "GH_TOKEN"

  # How long a resolution is trusted before the chain is consulted again.
  #
  # The caller is a once-a-minute cron path, and "just let the snapshot cache absorb
  # it" is not good enough: a name the store does NOT hold misses the snapshot, and
  # ParameterStoreProvider answers a miss by re-resolving the WHOLE namespace (a list,
  # then a render and a secret access per parameter, serially). On production — where
  # the store is configured but holds no GH_TOKEN, because this is staging-only — that
  # would turn a chain consulted at session spawn into continuous GCP API traffic on
  # the poller's critical path.
  #
  # So the refresh is clocked here rather than left to the provider. The cost is the
  # upper bound on how long a rotation takes to reach a running worker: this interval
  # plus the snapshot TTL.
  REFRESH_INTERVAL = 5.minutes

  # Serializes a refresh: the clock check, the chain read, and the ENV write are one
  # critical section. The poller refreshes on its own thread while sessions spawn on
  # GoodJob's `agents` threads, and ENV[]= mutates process-global `environ` — which is
  # not safe against another thread inside Process.spawn reading it. Holding the lock
  # across the whole thing also means a burst of concurrent callers produces ONE chain
  # read, not one each.
  MUTEX = Mutex.new

  class << self
    # Resolve the token and publish it to ENV["GH_TOKEN"].
    #
    # Idempotent and safe to call on every boot and every poll tick. At most one chain
    # read per REFRESH_INTERVAL: later calls inside the window return what is already
    # in ENV without touching the chain, which is what keeps the per-tick call free.
    #
    # Best-effort by design. A store that is unreachable RAISES out of the chain — the
    # chain deliberately does not fall through on a backend failure, because that is
    # how a rotated credential comes back from the dead — so this catches it here and
    # leaves whatever ENV already holds in place. Degrading to "the token we last
    # resolved" beats both crashing a boot and blanking a working credential. A failure
    # still arms the clock, so a persistently broken resolver logs once per interval
    # rather than once per tick.
    #
    # @param force [Boolean] resolve now, ignoring the refresh clock
    # @param logger [Logger] where to report
    # @return [String, nil] the token now in ENV, or nil when none is configured
    def ensure!(force: false, logger: Rails.logger)
      MUTEX.synchronize do
        return ENV[VARIABLE].presence unless force || due?

        @resolved_at = monotonic_now
        token = SecretProviders.chain.get(VARIABLE).presence
        return nil if token.nil?

        ENV[VARIABLE] = token unless ENV[VARIABLE] == token
        token
      end
    rescue => e
      # Report the class and message, never the value.
      logger.warn "[GhTokenProvisioner] Could not resolve #{VARIABLE}: #{e.class} - #{e.message}; " \
                  "leaving the existing environment in place (gh stays as it is)"
      ENV[VARIABLE].presence
    end

    # Drop the refresh clock, so the next ensure! consults the chain. For tests.
    def reset!
      MUTEX.synchronize { @resolved_at = nil }
    end

    private

    def due?
      @resolved_at.nil? || (monotonic_now - @resolved_at) >= REFRESH_INTERVAL
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
