# frozen_string_literal: true

# Materializes Zimmer's GitHub tokens into the process environment, sourced from
# the `${VAR}` chain (Parameter Store → encrypted credentials → ENV): GH_TOKEN, the
# default, and one GH_TOKEN__<OWNER> per further repository owner. GithubTokens
# holds the routing rule that decides which of them a call uses; this class only
# resolves, vets and publishes them.
#
# ## Why the environment, and not `gh auth login`
#
# Four different callers need GitHub auth, and only one of them is ours to pass an
# env hash to:
#
#   - GithubSearchService shells out to `gh api search/issues`, gated on
#     `gh auth status` — the GithubTriggerPollerJob path.
#   - GitCloneService runs `git clone`, and Dockerfile.base wires git's credential
#     helper to `bin/zimmer-git-credential`. Git spawns that helper itself, so the
#     only way to reach it is an inherited environment — which is also how the
#     helper gets the token map without a value ever appearing in an argv or a file.
#   - The other GitHub pollers (comments, PR status, merge conflicts) shell out
#     through GithubCli, which overrides GH_TOKEN per call with the target owner's
#     token (GithubTokens.env_for).
#   - Spawned agent sessions run `gh` themselves. They get a narrowed copy of the
#     map — their own owner's token as GH_TOKEN, nothing else (GithubTokens.session_env).
#
# `gh` reads GH_TOKEN straight from its environment, so the default token
# authenticates all four unless a caller overrides it for a specific owner. An
# interactive `gh auth login` would authenticate them too, but it does not survive
# container recreation, and its OAuth token reaches every organization the account
# belongs to.
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
# ## Why only fine-grained tokens, in production
#
# A fine-grained PAT (`github_pat_…`) is bound to one resource owner. An OAuth token
# (`gho_…`) or a classic PAT (`ghp_…`) reaches every organization its account belongs
# to — and the operator's account belongs to organizations nothing in Zimmer may
# touch. So a token without the `github_pat_` prefix is refused: not published, and
# whatever ENV held under that name removed, with the variable name and the reason
# logged and the value never. The guard is ZIMMER_GITHUB_REQUIRE_FINE_GRAINED_TOKENS:
# on by default in production, off by default everywhere else (staging authenticates
# as a separate test account whose token is not fine-grained, and dev uses whatever
# the developer has).
#
# ## Routing mode
#
# Once at least one token is published, ZIMMER_GITHUB_CREDENTIAL_ROUTING=1 is set too.
# That flag — not the presence of GH_TOKEN — is what tells the git helper to stop
# consulting the stored `gh auth login` credential. Until a token is seeded, nothing
# about how this deployment authenticates changes. See GithubTokens.
#
# ## The one staleness this accepts
#
# ENV is both an output of this class and the chain's last link. If a token is
# resolved from the store and later DELETED from it, the chain falls through to the
# ENV entry this class wrote and keeps serving it until the process restarts. The
# same holds for a whole GH_TOKEN__<OWNER>: it stays discoverable, from ENV. That is
# the deliberate trade for letting a plain `GH_TOKEN=…` keep working in dev and for a
# self-hoster: a delete is not a rotation, and a rotation (a new version at the same
# path) propagates normally.
class GhTokenProvisioner
  # The `${VAR}` name of the default token, which is also the environment variable
  # `gh` reads. Its canonical store path is ParameterStore::Namespace.parameter_path("GH_TOKEN")
  # — /zimmer/{env}/secrets/static/GH_TOKEN; an owner's token sits beside it at
  # .../GH_TOKEN__<OWNER>. It is also the reason that namespace is named what it is:
  # a `gh` CLI token was never an MCP secret.
  VARIABLE = GithubTokens::DEFAULT_VARIABLE

  # The prefix every fine-grained personal access token carries.
  FINE_GRAINED_PREFIX = "github_pat_"

  # "true"/"false" overrides the per-environment default below.
  REQUIRE_FINE_GRAINED_VARIABLE = "ZIMMER_GITHUB_REQUIRE_FINE_GRAINED_TOKENS"

  # How long a resolution is trusted before the chain is consulted again.
  #
  # The caller is a once-a-minute cron path, and "just let the snapshot cache absorb
  # it" is not good enough: a name the store does NOT hold misses the snapshot, and
  # ParameterStoreProvider answers a miss by re-resolving the WHOLE namespace (a list,
  # then a render and a secret access per parameter, serially). On a deployment
  # whose store is configured but holds no GH_TOKEN, that would turn a chain
  # consulted at session spawn into continuous GCP API traffic on the poller's
  # critical path.
  #
  # So the refresh is clocked here rather than left to the provider. The cost is the
  # upper bound on how long a rotation — or a newly seeded owner — takes to reach a
  # running worker: this interval plus the snapshot TTL.
  REFRESH_INTERVAL = 5.minutes

  # Serializes a refresh: the clock check, the chain reads, and the ENV writes are one
  # critical section, so a burst of concurrent callers produces ONE chain pass, not one
  # each, and two refreshes never interleave their writes. It does not serialize the
  # READERS — Process.spawn on GoodJob's `agents` threads, GithubTokens, the status
  # line — which read ENV without it. That is safe on MRI, where each ENV access and
  # the env a spawn builds happen under the GVL, so a reader sees a variable either
  # before or after a write, never half of one. A reader can see the map mid-refresh
  # (one owner rotated, another not yet), which is the same state as the moment
  # between two refreshes.
  MUTEX = Mutex.new

  class << self
    # Resolve every token and publish it to ENV.
    #
    # Idempotent and safe to call on every boot and every poll tick. At most one chain
    # pass per REFRESH_INTERVAL: later calls inside the window return what is already
    # in ENV without touching the chain, which is what keeps the per-tick call free.
    #
    # Best-effort by design. A store that is unreachable RAISES out of the chain — the
    # chain deliberately does not fall through on a backend failure, because that is
    # how a rotated credential comes back from the dead — so this catches it here and
    # leaves whatever ENV already holds in place. Degrading to "the tokens we last
    # resolved" beats both crashing a boot and blanking a working credential. A failure
    # still arms the clock, so a persistently broken resolver logs once per interval
    # rather than once per tick.
    #
    # @param force [Boolean] resolve now, ignoring the refresh clock
    # @param logger [Logger] where to report
    # @return [String, nil] the default token now in ENV, or nil when none is configured
    def ensure!(force: false, logger: Rails.logger)
      MUTEX.synchronize do
        return ENV[VARIABLE].presence unless force || due?

        @resolved_at = monotonic_now
        chain = SecretProviders.chain
        published = variables(chain).count { |variable| publish(variable, chain.get(variable).presence, logger) }

        if published.positive?
          ENV[GithubTokens::ROUTING_VARIABLE] = "1"
        else
          ENV.delete(GithubTokens::ROUTING_VARIABLE)
        end

        ENV[VARIABLE].presence
      end
    rescue => e
      # Report the class and message, never the value.
      logger.warn "[GhTokenProvisioner] Could not resolve the GitHub tokens: #{e.class} - #{e.message}; " \
                  "leaving the existing environment in place (gh stays as it is)"
      ENV[VARIABLE].presence
    end

    # Whether a token that is not fine-grained is refused.
    def require_fine_grained?(env: ENV)
      configured = env[REQUIRE_FINE_GRAINED_VARIABLE].presence
      return ActiveModel::Type::Boolean.new.cast(configured) unless configured.nil?

      Rails.env.production?
    end

    # Why `token` may not be published, or nil when it may. Never echoes the value.
    def refusal_reason(token)
      return nil unless require_fine_grained?
      return nil if token.start_with?(FINE_GRAINED_PREFIX)

      kind = case token
      when /\Agho_/ then "an OAuth token (gho_)"
      when /\Aghp_/ then "a classic personal access token (ghp_)"
      when /\Aghs_|\Aghu_/ then "a GitHub App token"
      else "not a recognised GitHub token format"
      end
      "#{kind}, which reaches every organization its account belongs to; " \
        "only fine-grained tokens (#{FINE_GRAINED_PREFIX}…) are accepted while " \
        "#{REQUIRE_FINE_GRAINED_VARIABLE} is on"
    end

    # Drop the refresh clock, so the next ensure! consults the chain. For tests.
    def reset!
      MUTEX.synchronize { @resolved_at = nil }
    end

    private

    # GH_TOKEN plus every GH_TOKEN__<OWNER> any link of the chain holds.
    def variables(chain)
      owners = chain.respond_to?(:names) ? chain.names.select { |name| GithubTokens.owner_variable?(name) } : []
      [ VARIABLE, *owners.sort ]
    end

    # @return [Boolean] whether a token is now published under `variable`
    def publish(variable, token, logger)
      return false if token.nil?

      if (reason = refusal_reason(token))
        logger.warn "[GhTokenProvisioner] Refusing #{variable} " \
                    "(owner #{GithubTokens.owner_for_variable(variable) || 'default'}): #{reason}"
        # Whatever ENV holds under this name goes too — the refused value itself, or an
        # older one the chain no longer answers with. Either way the chain's answer for
        # the variable is "refused", and leaving a token live under it would leave gh
        # using it with routing off.
        ENV.delete(variable)
        return false
      end

      ENV[variable] = token unless ENV[variable] == token
      true
    end

    def due?
      @resolved_at.nil? || (monotonic_now - @resolved_at) >= REFRESH_INTERVAL
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
