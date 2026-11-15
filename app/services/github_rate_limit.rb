# frozen_string_literal: true

# What Zimmer knows about GitHub's rate-limit budgets, and the rule GithubCli applies
# before it spends any of them.
#
# ## Why this exists
#
# On 2026-11-15 the REST `core` budget for the tadasant user (5000/hr, counted per user
# across every token that user holds, so agent sessions running `gh` spend it too) ran
# out at 21:08Z. Zimmer's own callers did not notice. Github::CommentEvaluator,
# Github::PrSnapshot and the trigger poller's `gh auth status` preflight kept calling,
# and logged 586 `API rate limit exceeded` failures in 19 minutes. Each of those calls was
# refused, and a refused call still counts against the budget. The preflight failing is what made
# it an outage: it gates the whole trigger sweep, so every watched repository went dark until
# the window reset at 21:27Z.
#
# Three rules come out of that:
#
#   1. **Stop calling a budget that is spent.** The first call that GitHub refuses with a
#      primary rate limit trips a breaker for that credential and that budget, until the
#      reset time GitHub reports. Every later call against it is answered locally, with a
#      failed GithubCli::Result that never reaches GitHub. The reset time comes from
#      `gh api rate_limit`, which GitHub does not count against any budget. `gh`'s own
#      error line does not carry it. If that probe fails too, the breaker holds for
#      FALLBACK_HOLD and the next refused call probes again.
#   2. **Keep a reserve for the trigger poller.** GithubRateLimitSnapshotJob reads every
#      credential's budgets once a minute. Ordinary callers stand down once a budget's
#      remaining count is below RESERVE. The poller's preflight runs at `priority: :poller`
#      and may spend the reserve. The reserve can only hold back Zimmer's own callers.
#      Agent sessions running `gh` as the same user are outside its reach, which is why
#      the poller must also survive the budget running out entirely (see below).
#   3. **Say what happened.** A spent budget is reported as rate-limited until a stated
#      time, in GithubSearchService.auth_preflight's state, in the poller's WARN, and in
#      the stalled-polling page's details (.diagnosis). It is not reported as GitHub being
#      unreachable.
#
# Budgets are separate. GitHub keeps `core` (REST), `graphql` and `search` apart, and the
# trigger poller's sweep spends only `search`. Spending all of `core` therefore takes the
# preflight away and leaves the sweep itself able to run. That is why each breaker is keyed by
# budget as well as by credential, and why GithubTriggerPollerJob polls through a
# rate-limited preflight instead of skipping the tick.
#
# ## Failing open
#
# Everything here is advisory and fails open. A cache that cannot be read, a snapshot
# that has aged out, a probe that cannot be parsed: each one means "no breaker, no
# reserve" and the call goes ahead exactly as it would have without this module. The
# worst case of this module failing is the behaviour before it existed, never a call
# withheld for a reason nobody can see.
module GithubRateLimit
  # The budgets this module tracks, by the name GitHub's `rate_limit` endpoint uses.
  RESOURCES = %w[core graphql search].freeze

  # Remaining calls below which an ordinary (non-poller) caller stands down until the
  # window resets. 500 of 5000 is about the last ten minutes of a busy hour. The poller's
  # preflight is one `core` call a minute, so the reserve covers it many times over.
  #
  # No reserve on `search`. Its budget is 30 a minute and resets every minute, the
  # poller is its main spender, and GithubSearchService already backs off on a refusal.
  RESERVE = { "core" => 500, "graphql" => 500 }.freeze

  # How long a breaker holds when GitHub refused a call with a primary rate limit but
  # the free probe could not tell us when the window resets. Short, so a wrong guess
  # costs a minute; the next refused call after it probes again.
  FALLBACK_HOLD = 60.seconds

  # A snapshot older than this is not trusted to hold anyone back. GithubRateLimitSnapshotJob
  # refreshes it every minute; a snapshot this old means the job is not running, and an
  # aged reading of "remaining" says nothing about now.
  SNAPSHOT_TTL = 3.minutes

  PROBE_TIMEOUT = 10

  PROBE_COMMAND = [ "gh", "api", "rate_limit" ].freeze

  CACHE_PREFIX = "github_rate_limit"

  # The credential id for a host with no GH_TOKEN, running on `gh auth login`'s stored login.
  AMBIENT_ID = "ambient"

  # GitHub's wording for a spent primary budget, from REST (`API rate limit exceeded
  # for user ID 3900899.`) and from GraphQL (`API rate limit already exceeded for user
  # ID …`). A secondary limit (`You have exceeded a secondary rate limit`) is a
  # different thing, a burst limit with a Retry-After, and does not trip a breaker.
  #
  # A match only triggers a probe. The probe is what trips the breaker, and it trips
  # only the budgets GitHub reports as spent. A stray match (a label named after this
  # sentence, echoed back in a search error) costs one free call.
  PRIMARY_EXHAUSTION_PATTERN = /API rate limit (?:already )?exceeded/i

  # Why a call was answered locally instead of being sent.
  #
  #   kind:        :exhausted (GitHub refused this budget, and the window has not reset)
  #                or :reserve (the budget is under RESERVE and the caller is not the poller)
  #   resource:    "core", "graphql" or "search"
  #   reset_at:    when GitHub's window resets, so when this stops applying
  #   remaining:   the last count GitHub reported (nil for :exhausted, where it is 0)
  #   credential:  which variable holds the token, e.g. "GH_TOKEN" — a name, never a value
  Refusal = Data.define(:kind, :resource, :reset_at, :remaining, :credential) do
    def message
      reason = if kind == :exhausted
        "GitHub's API rate limit exceeded for #{credential}'s #{resource} budget"
      else
        "holding back #{credential}'s #{resource} budget for the trigger poller " \
          "(#{remaining} remaining, under the reserve of #{RESERVE[resource]})"
      end
      "not sent to GitHub: #{reason} until #{reset_at.utc.iso8601}"
    end
  end

  module_function

  # Which budget a `gh` argv spends, or nil when it spends none that we track.
  #
  # `gh api rate_limit` is nil: GitHub does not count it, and it is the probe. Answering it
  # locally during an outage would leave the breaker unable to learn when the window
  # resets. `gh pr …` and `gh issue …` go through GraphQL. Everything else that reaches
  # the network, including `gh auth status`, spends `core`.
  def resource_for(command)
    args = Array(command).map(&:to_s)
    return nil unless args.first == "gh"

    case args[1]
    when "api"
      rest = args.drop(2)
      return nil if rest.any? { |arg| arg.match?(%r{\A/?rate_limit\z}) }
      return "graphql" if rest.include?("graphql")
      return "search" if rest.any? { |arg| arg.match?(%r{\A/?search/}) }

      "core"
    when "pr", "issue"
      "graphql"
    else
      "core"
    end
  end

  # The Refusal for a call about to be made, or nil to let it through.
  #
  # @param command [Array<String>] the `gh` argv
  # @param env [Hash] the extra environment GithubCli will run it with
  # @param priority [Symbol] :poller may spend the reserve; anything else may not
  def refusal_for(command, env: {}, priority: :normal)
    resource = resource_for(command)
    return nil unless resource

    credential = credential_for(env)
    exhausted_until = read_exhausted(credential, resource)
    if exhausted_until
      return Refusal.new(kind: :exhausted, resource: resource, reset_at: exhausted_until,
                         remaining: 0, credential: credential[:label])
    end

    return nil if priority == :poller

    reserve = RESERVE[resource]
    return nil unless reserve

    budget = snapshot(credential)&.dig(resource)
    return nil unless budget && budget[:remaining] < reserve && budget[:reset_at].future?

    Refusal.new(kind: :reserve, resource: resource, reset_at: budget[:reset_at],
                remaining: budget[:remaining], credential: credential[:label])
  rescue => e
    Rails.logger.warn "[GithubRateLimit] Could not check the rate-limit breaker (#{e.class}: #{e.message}); " \
                      "letting the call through"
    nil
  end

  # Called with the text of a `gh` call that failed. If GitHub refused it with a primary
  # rate limit, probe the budgets and trip a breaker on every one of them that is spent.
  #
  # @return [Refusal, nil] the breaker now covering this call's budget, if any
  def observe_failure(command, text, env: {})
    return nil unless text.to_s.match?(PRIMARY_EXHAUSTION_PATTERN)

    resource = resource_for(command)
    return nil unless resource

    record_exhaustion(credential_for(env), fallback_resource: resource)
  rescue => e
    Rails.logger.warn "[GithubRateLimit] Could not record a rate-limit refusal (#{e.class}: #{e.message})"
    nil
  end

  # Probe one credential's budgets and remember them. Trips a breaker on every budget
  # GitHub reports as spent. Used by GithubRateLimitSnapshotJob and on a refused call.
  #
  # @return [Hash, nil] the budgets read, or nil when the probe failed
  def refresh(credential)
    budgets = probe(credential)
    return nil unless budgets

    Rails.cache.write(snapshot_key(credential), budgets.transform_values { |b| serialize(b) },
                      expires_in: SNAPSHOT_TTL)
    budgets.each do |resource, budget|
      trip(credential, resource, budget[:reset_at]) if budget[:remaining].zero? && budget[:reset_at].future?
    end
    budgets
  end

  # Every credential GithubCli may run `gh` with: the default GH_TOKEN, each
  # GH_TOKEN__<OWNER>, and, when neither is set, whatever `gh auth login` stored.
  # Distinct token values only, since two variables holding the same token share a budget.
  #
  # Each is { label:, id:, owner: }. `id` is a short digest of the token, so the cache never
  # holds the token itself. `owner` is what to hand GithubCli.run to spend this credential:
  # nil for the default GH_TOKEN (and the stored login), the owner for a GH_TOKEN__<OWNER>.
  def credentials(env: ENV)
    found = []
    if (token = env[GithubTokens::DEFAULT_VARIABLE].presence)
      found << { label: GithubTokens::DEFAULT_VARIABLE, id: digest(token), owner: nil }
    end
    GithubTokens.owner_variables(env: env).sort_by(&:last).each do |owner, variable|
      found << { label: variable, id: digest(env[variable]), owner: owner }
    end
    found = [ ambient_credential ] if found.empty?
    found.uniq { |credential| credential[:id] }
  end

  # One paragraph for the stalled-polling page: every budget Zimmer knows to be spent or
  # in reserve, with its reset time. Nil when nothing is known to be wrong. In that case the
  # page's other causes (a dead worker, a hung `gh`, GitHub down) are the ones to check.
  def diagnosis(env: ENV)
    findings = credentials(env: env).flat_map do |credential|
      budgets = snapshot(credential) || {}
      RESOURCES.filter_map do |resource|
        exhausted_until = read_exhausted(credential, resource)
        if exhausted_until
          "#{credential[:label]}'s #{resource} budget is spent until #{exhausted_until.utc.iso8601}"
        elsif (budget = budgets[resource]) && RESERVE[resource] && budget[:remaining] < RESERVE[resource] &&
              budget[:reset_at].future?
          "#{credential[:label]}'s #{resource} budget is down to #{budget[:remaining]}/#{budget[:limit]} " \
            "until #{budget[:reset_at].utc.iso8601}"
        end
      end
    end
    return nil if findings.empty?

    "GitHub rate limit: #{findings.join('; ')}. GitHub counts the 5000/hr REST budget per user across " \
      "every token that user holds, so agent sessions running `gh` as the same user spend it too."
  rescue => e
    Rails.logger.warn "[GithubRateLimit] Could not read rate-limit state for a diagnosis (#{e.class}: #{e.message})"
    nil
  end

  # --- internals ---------------------------------------------------------------

  def credential_for(env)
    token = env[GithubTokens::DEFAULT_VARIABLE].presence || ENV[GithubTokens::DEFAULT_VARIABLE].presence
    return ambient_credential unless token

    id = digest(token)
    credentials.find { |credential| credential[:id] == id } ||
      { label: GithubTokens::DEFAULT_VARIABLE, id: id, owner: nil }
  end

  def ambient_credential
    { label: "the stored gh login", id: AMBIENT_ID, owner: nil }
  end

  def digest(token)
    Digest::SHA256.hexdigest(token)[0, 16]
  end

  def record_exhaustion(credential, fallback_resource:)
    refresh(credential) || trip(credential, fallback_resource, FALLBACK_HOLD.from_now)

    reset_at = read_exhausted(credential, fallback_resource)
    return nil unless reset_at

    Refusal.new(kind: :exhausted, resource: fallback_resource, reset_at: reset_at, remaining: 0,
                credential: credential[:label])
  end

  # Open a breaker. Logs once per breaker, not once per call: `unless_exist` makes the
  # first writer the only one that logs.
  def trip(credential, resource, reset_at)
    # A few seconds past GitHub's reset, so the first call after it lands in the new window.
    expires_in = (reset_at - Time.current) + 5
    return if expires_in <= 0

    opened = Rails.cache.write(exhausted_key(credential, resource), reset_at.to_i,
                               expires_in: expires_in, unless_exist: true)
    return unless opened

    Rails.logger.warn "[GithubRateLimit] GitHub's #{resource} rate limit is spent for #{credential[:label]} " \
                      "until #{reset_at.utc.iso8601}; Zimmer's #{resource} calls on that credential are " \
                      "answered locally until then instead of being refused by GitHub"
  end

  def read_exhausted(credential, resource)
    value = Rails.cache.read(exhausted_key(credential, resource))
    return nil unless value

    reset_at = Time.zone.at(value.to_i)
    reset_at.future? ? reset_at : nil
  end

  def snapshot(credential)
    raw = Rails.cache.read(snapshot_key(credential))
    return nil unless raw.is_a?(Hash)

    raw.transform_values do |budget|
      { remaining: budget["remaining"].to_i, limit: budget["limit"].to_i,
        reset_at: Time.zone.at(budget["reset"].to_i) }
    end
  end

  # `gh api rate_limit`. It goes through GithubCli like every other `gh` call, and
  # .resource_for exempts it, so the breaker it feeds can never answer it.
  def probe(credential)
    result = GithubCli.run(PROBE_COMMAND, timeout: PROBE_TIMEOUT, owner: credential[:owner])
    unless result.success?
      Rails.logger.warn "[GithubRateLimit] gh api rate_limit failed for #{credential[:label]}: " \
                        "#{result.failure_description}"
      return nil
    end

    resources = JSON.parse(result.stdout)["resources"]
    return nil unless resources.is_a?(Hash)

    RESOURCES.each_with_object({}) do |resource, budgets|
      budget = resources[resource]
      next unless budget.is_a?(Hash) && budget["remaining"] && budget["reset"]

      budgets[resource] = { remaining: budget["remaining"].to_i, limit: budget["limit"].to_i,
                            reset_at: Time.zone.at(budget["reset"].to_i) }
    end.presence
  rescue JSON::ParserError, SystemCallError => e
    Rails.logger.warn "[GithubRateLimit] gh api rate_limit failed for #{credential[:label]}: #{e.class}: #{e.message}"
    nil
  end

  def serialize(budget)
    { "remaining" => budget[:remaining], "limit" => budget[:limit], "reset" => budget[:reset_at].to_i }
  end

  def exhausted_key(credential, resource)
    "#{CACHE_PREFIX}:exhausted:#{credential[:id]}:#{resource}"
  end

  def snapshot_key(credential)
    "#{CACHE_PREFIX}:snapshot:#{credential[:id]}"
  end
end
