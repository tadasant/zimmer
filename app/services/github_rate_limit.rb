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
#      error line does not carry it. If that probe fails too, or contradicts the refusal,
#      the breaker holds on an exponential backoff instead (rule 4).
#   2. **Let the trigger poller run through it.** The poller's sweep spends only the
#      search budget, so a spent core budget costs it nothing but its `gh auth status`
#      preflight, and GithubTriggerPollerJob polls through a rate-limited preflight. That
#      is the protection that holds against callers Zimmer cannot limit, such as agent
#      sessions running `gh` as the same user. A reserve that held Zimmer's other callers
#      back below some remaining count would buy the poller nothing on top of that, and
#      would cost the merge gate its PR reads for the last stretch of every busy hour.
#      GithubRateLimitSnapshotJob reads every credential's budgets once a minute. A
#      budget it finds spent trips the breaker before any caller is refused, and the
#      readings feed .diagnosis.
#   3. **Do not all come back at once.** Every caller shares one breaker, so a breaker that
#      reopened at exactly `reset` would release every waiting caller in the same second,
#      and the first second of the new window would go to whoever's tick landed first.
#      Each call draws its own reopen time from [reset, reset + REOPEN_JITTER[budget]], so
#      Zimmer's callers come back spread across that window instead (see REOPEN_JITTER).
#   4. **Back off where GitHub gives no reset time.** A secondary rate limit (GitHub's
#      burst limit, answered 403 or 429), a primary refusal the probe cannot date, and a
#      refusal met again right after a reopen all hold the breaker on a capped exponential
#      backoff with full jitter (.backoff_hold), or for exactly GitHub's `Retry-After` when
#      the response carries one. The attempt count is per credential and budget, and the
#      first call GitHub answers without a rate limit resets it.
#   5. **Keep the trigger poller's search budget.** GitHub's search budget is 30 a minute,
#      and the trigger poller spends it once a minute, one search per condition. Zimmer's
#      other search callers (the Issues page, the hourly trigger health check) are bursty,
#      and a cold Issues page load alone spends most of a minute's budget. Outside
#      .on_poller_budget they may spend only what the poller's next tick will not need
#      (.charge_search_share); past that their searches are answered locally until the
#      window ends.
#   6. **Say what happened.** A spent budget is reported as rate-limited until a stated
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
# Everything here is advisory and fails open. A cache that cannot be read or a probe that
# cannot be parsed means "no breaker", and the call goes ahead exactly as it would have
# without this module. The worst case of this module failing is GitHub refusing the call
# itself, never a call withheld for a reason nobody can see.
module GithubRateLimit
  # The budgets this module tracks, by the name GitHub's `rate_limit` endpoint uses.
  RESOURCES = %w[core graphql search].freeze

  # Remaining calls below which .diagnosis reports a budget as running low, so a stall
  # page in the minutes before exhaustion still names the cause. Reporting only.
  LOW_WATER = 500

  # How far past GitHub's reset a call may be held back, per budget. Each call draws its
  # own reopen time uniformly from [reset, reset + this], so the callers queued behind a
  # breaker come back spread across the window rather than in the same second.
  #
  # core and graphql reset hourly. 30 seconds is at most 0.8% of the new window, and it
  # is longer than the tick of the busiest caller (the PR poll pass, every 30 seconds), so
  # a full round of Zimmer's callers spreads across it instead of landing at once. search
  # resets every minute and its one regular spender, the trigger poller, ticks once a
  # minute. Holding it back 30 seconds would cost the poller half a window and make a
  # skipped tick likely, so it gets 5.
  REOPEN_JITTER = { "core" => 30, "graphql" => 30, "search" => 5 }.freeze
  DEFAULT_REOPEN_JITTER = 30

  # Backoff for a rate limit GitHub gave no reset time for (see .backoff_hold). The
  # n-th consecutive hold is
  #
  #   floor + rand(0 .. min(BACKOFF_CAP, BACKOFF_BASE * 2**(n - 1)))
  #
  # which is full jitter above a floor. The floor is GitHub's own rule for a secondary
  # limit with no Retry-After ("wait for at least one minute before retrying"), and a few
  # seconds where the probe merely failed. The base matches that minute; the cap keeps a
  # long run of refusals from holding a budget past a quarter of an hour, which is also
  # past GithubTriggerPollerJob's five-tick streak alarm, so a backoff that is not clearing
  # still pages.
  BACKOFF_BASE = 60
  BACKOFF_CAP = 15.minutes.to_i
  SECONDARY_FLOOR = 60
  UNDATED_FLOOR = 5

  # How long a run of backoff attempts is remembered with no call in between. A call
  # GitHub answers without a rate limit clears it sooner.
  BACKOFF_MEMORY = 1.hour

  # GitHub's search budget per window, for every token the user holds.
  SEARCH_BUDGET = 30

  # How much of each search window Zimmer's callers other than the trigger poller may spend
  # on one credential (rule 5): SEARCH_BUDGET less what one poller tick spends, which is one
  # search per enabled GitHub trigger condition. That reserve is capped at MAX_POLLER_RESERVE,
  # so the others always keep at least half. The Issues page needs about 25 searches for a
  # cold load and the poller a handful, so a fixed split would cut one of them short for no
  # reason; this one costs the page only what the poller is actually going to spend.
  #
  # It cannot protect against agent sessions running `gh search` as the same user. Nothing
  # in Zimmer can.
  MAX_POLLER_RESERVE = 15
  POLLER_RESERVE_TTL = 5.minutes
  SEARCH_WINDOW = 60

  # A snapshot older than this is not reported. GithubRateLimitSnapshotJob refreshes it
  # every minute; a snapshot this old means the job is not running, and an aged reading of
  # "remaining" says nothing about now.
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

  # GitHub's wording for a secondary (burst) limit, matched as GitHub's whole sentences for
  # the reason GithubSearchService::GH_RATE_LIMIT_PATTERN gives: `gh` echoes a search query
  # back in its error, and a fragment would let a label of that name forge one.
  SECONDARY_LIMIT_PATTERN = /
    You\ have\ exceeded\ a\ secondary\ rate\ limit
    | You\ have\ triggered\ an\ abuse\ detection\ mechanism
  /xi

  # `gh` prints the status on its error line: `… (HTTP 403)`.
  HTTP_STATUS_PATTERN = /\(HTTP (\d{3})\)/

  # The statuses GitHub answers a rate limit with. A 429 is only ever a rate limit.
  RATE_LIMIT_STATUSES = [ 403, 429 ].freeze

  # A `Retry-After` header, present when the caller asked `gh api` to include headers.
  RETRY_AFTER_PATTERN = /^Retry-After:\s*(\d+)\s*$/i

  # The same refusal, made to an authenticated request: GitHub names the user it is
  # refusing. Only this form says the credential is valid. An unauthenticated request is
  # refused per IP (`API rate limit exceeded for 203.0.113.7`), which proves nothing.
  CREDENTIAL_EXHAUSTION_PATTERN = /API rate limit (?:already )?exceeded for user ID/i

  # Why a call was answered locally instead of being sent.
  #
  #   resource:    "core", "graphql" or "search"
  #   reset_at:    when GitHub's window resets (kind :exhausted), when the backoff hold ends
  #                (:backoff), or when the search window ends (:share)
  #   credential:  which variable holds the token, e.g. "GH_TOKEN" — a name, never a value
  #   retry_at:    when this call would have been let through: reset_at plus this call's
  #                share of REOPEN_JITTER. Always at or after reset_at.
  #   kind:        :exhausted (GitHub said the budget is spent), :backoff (a rate limit with
  #                no reset time), or :share (the poller's share of the search budget)
  Refusal = Data.define(:resource, :reset_at, :credential, :retry_at, :kind) do
    def initialize(resource:, reset_at:, credential:, retry_at: reset_at, kind: :exhausted)
      super
    end

    def message
      case kind
      when :backoff
        "not sent to GitHub: backing off after GitHub rate-limited #{credential}'s #{resource} " \
          "budget, until #{retry_at.utc.iso8601}"
      when :share
        "not sent to GitHub: Zimmer's searches outside the trigger poller have spent their " \
          "share of #{credential}'s search budget for this minute, until #{retry_at.utc.iso8601}"
      else
        "not sent to GitHub: GitHub's API rate limit exceeded for #{credential}'s #{resource} " \
          "budget until #{reset_at.utc.iso8601}"
      end
    end
  end

  module_function

  # Which budget a `gh` argv spends, or nil when it spends none that we track.
  #
  # `gh api rate_limit` is nil: GitHub does not count it, and it is the probe. Answering it
  # locally during an outage would leave the breaker unable to learn when the window
  # resets. `gh auth` subcommands other than `status` are local and nil too. `gh pr`,
  # `gh issue` and `gh repo` go through GraphQL, `gh search` through search. Everything
  # else that reaches the network, including `gh auth status`, spends `core`.
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
    when "auth"
      args[2] == "status" ? "core" : nil
    when "pr", "issue", "repo"
      "graphql"
    when "search"
      "search"
    when "--version", "version", "help", "config", "alias", "completion"
      nil
    else
      "core"
    end
  end

  # The Refusal for a call about to be made, or nil to let it through. Reads only; see
  # .admit for the check GithubCli makes, which also charges the search share.
  #
  # @param command [Array<String>] the `gh` argv
  # @param env [Hash] the extra environment GithubCli will run it with
  def refusal_for(command, env: {})
    resource = resource_for(command)
    return nil unless resource

    credential = credential_for(env)
    hold = read_hold(credential, resource)
    return nil unless hold

    # Drawn per call, so callers queued behind one breaker reopen at different moments.
    retry_at = hold[:reset_at] + (random * hold[:spread])
    return nil unless retry_at.future?

    Refusal.new(resource: resource, reset_at: hold[:reset_at], credential: credential[:label],
                retry_at: retry_at, kind: hold[:kind])
  rescue => e
    Rails.logger.warn "[GithubRateLimit] Could not check the rate-limit breaker (#{e.class}: #{e.message}); " \
                      "letting the call through"
    nil
  end

  # What GithubCli asks before sending a call: .refusal_for, and, for a search sent outside
  # .on_poller_budget, a charge against the non-poller share (.charge_search_share).
  def admit(command, env: {})
    refusal = refusal_for(command, env: env)
    return refusal if refusal
    return nil unless resource_for(command) == "search" && !on_poller_budget?

    charge_search_share(credential_for(env))
  rescue => e
    Rails.logger.warn "[GithubRateLimit] Could not check the search share (#{e.class}: #{e.message}); " \
                      "letting the call through"
    nil
  end

  # Run the block with its searches on the trigger poller's budget: exempt from the
  # non-poller share. Only GithubTriggerPollerJob's sweep should use this.
  def on_poller_budget
    previous = ActiveSupport::IsolatedExecutionState[:github_rate_limit_poller]
    ActiveSupport::IsolatedExecutionState[:github_rate_limit_poller] = true
    yield
  ensure
    ActiveSupport::IsolatedExecutionState[:github_rate_limit_poller] = previous
  end

  def on_poller_budget?
    ActiveSupport::IsolatedExecutionState[:github_rate_limit_poller] == true
  end

  # Called by GithubCli with what every sent call printed. A rate-limit refusal is recorded
  # (.observe_failure); any other answer means GitHub served this budget, so the backoff
  # for it starts over.
  def observe(command, stderr, stdout: "", env: {})
    return if observe_failure(command, stderr, stdout: stdout, env: env)

    resource = resource_for(command)
    return unless resource

    Rails.cache.delete(backoff_key(credential_for(env), resource))
  rescue => e
    Rails.logger.warn "[GithubRateLimit] Could not reset the rate-limit backoff (#{e.class}: #{e.message})"
    nil
  end

  # Called with the text of a `gh` call that GitHub may have rate-limited.
  #
  # A primary limit probes the budgets and trips a breaker on every one of them that is
  # spent. If the probe fails, or does not show this call's budget as spent with a reset
  # still ahead, the breaker holds on .backoff_hold instead. A secondary limit holds on
  # `Retry-After` when the response carries one, and on .backoff_hold otherwise.
  #
  # @return [Refusal, nil] the breaker now covering this call's budget, if GitHub refused it
  def observe_failure(command, text, stdout: "", env: {})
    kind = rate_limit_kind(text)
    return nil unless kind

    resource = resource_for(command)
    return nil unless resource

    credential = credential_for(env)
    if kind == :primary
      record_exhaustion(credential, fallback_resource: resource)
    else
      record_secondary(credential, resource, retry_after_in(text, stdout))
    end
  rescue => e
    Rails.logger.warn "[GithubRateLimit] Could not record a rate-limit refusal (#{e.class}: #{e.message})"
    nil
  end

  # The next moment Zimmer will send a call on each budget it is holding back, for a status
  # surface that wants it: one entry per credential and budget with a breaker open.
  #
  # @return [Array<Hash>] { credential:, resource:, kind:, reset_at:, retry_by: } where
  #   retry_by is the latest any caller is held back (reset_at plus the full jitter window)
  def holds(env: ENV)
    credentials(env: env).flat_map do |credential|
      RESOURCES.filter_map do |resource|
        hold = read_hold(credential, resource)
        next unless hold

        retry_by = hold[:reset_at] + hold[:spread]
        next unless retry_by.future?

        { credential: credential[:label], resource: resource, kind: hold[:kind],
          reset_at: hold[:reset_at], retry_by: retry_by }
      end
    end
  rescue => e
    Rails.logger.warn "[GithubRateLimit] Could not read rate-limit holds (#{e.class}: #{e.message})"
    []
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
  # running low (under LOW_WATER), with its reset time. Nil when nothing is known to be wrong. In that case the
  # page's other causes (a dead worker, a hung `gh`, GitHub down) are the ones to check.
  def diagnosis(env: ENV)
    findings = credentials(env: env).flat_map do |credential|
      budgets = snapshot(credential) || {}
      RESOURCES.filter_map do |resource|
        exhausted_until = read_exhausted(credential, resource)
        if exhausted_until
          "#{credential[:label]}'s #{resource} budget is spent until #{exhausted_until.utc.iso8601}"
        elsif (budget = budgets[resource]) && resource != "search" && budget[:remaining] < LOW_WATER &&
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
    budgets = refresh(credential)
    unless read_exhausted(credential, fallback_resource)
      # GitHub refused the call for a spent budget, and the probe either failed or cannot
      # say until when. GitHub's refusal is the stronger evidence, so hold, briefly at
      # first and longer if it keeps happening.
      trip(credential, fallback_resource, backoff_hold(credential, fallback_resource, floor: UNDATED_FLOOR).from_now,
           kind: :backoff, spread: 0, why: budgets ? "the rate-limit probe still shows budget left" : "the rate-limit probe failed")
    end

    refusal_after_trip(credential, fallback_resource)
  end

  def record_secondary(credential, resource, retry_after)
    if retry_after
      bump_backoff(credential, resource)
      trip(credential, resource, retry_after.seconds.from_now, kind: :backoff,
           spread: REOPEN_JITTER.fetch(resource, DEFAULT_REOPEN_JITTER), why: "secondary rate limit, Retry-After #{retry_after}s")
    else
      trip(credential, resource, backoff_hold(credential, resource, floor: SECONDARY_FLOOR).from_now,
           kind: :backoff, spread: 0, why: "secondary rate limit")
    end

    refusal_after_trip(credential, resource)
  end

  def refusal_after_trip(credential, resource)
    hold = read_hold(credential, resource)
    return nil unless hold && hold[:reset_at].future?

    Refusal.new(resource: resource, reset_at: hold[:reset_at], credential: credential[:label], kind: hold[:kind])
  end

  # How long to hold for the next attempt in a run of undated rate limits on this credential
  # and budget: `floor + rand(0 .. min(BACKOFF_CAP, BACKOFF_BASE * 2**(n - 1)))`. Bumps n.
  def backoff_hold(credential, resource, floor:)
    attempt = bump_backoff(credential, resource)
    ceiling = [ BACKOFF_CAP, BACKOFF_BASE * (2**(attempt - 1)) ].min
    (floor + (random * ceiling)).seconds
  end

  # The attempt number this one is, 1 for the first in a run.
  def bump_backoff(credential, resource)
    key = backoff_key(credential, resource)
    attempt = Rails.cache.read(key).to_i + 1
    # Capped so the exponent cannot grow without bound; BACKOFF_CAP is reached long before.
    Rails.cache.write(key, [ attempt, 32 ].min, expires_in: BACKOFF_MEMORY)
    attempt
  end

  # Count this search against the non-poller share, and refuse it if the share for this
  # window is spent. The counter's expiry is set by the first search in a window and not
  # moved by the rest, which is how GitHub dates its own search window. A cache that cannot
  # count (nil) lets the search through. The reserve is read only once the count is past
  # the point where it could matter.
  def charge_search_share(credential)
    count = Rails.cache.increment(search_share_key(credential), 1, expires_in: SEARCH_WINDOW)
    return nil unless count && count > SEARCH_BUDGET - MAX_POLLER_RESERVE
    return nil unless count > SEARCH_BUDGET - poller_search_reserve

    reset_at = SEARCH_WINDOW.seconds.from_now
    Refusal.new(resource: "search", reset_at: reset_at, credential: credential[:label], kind: :share)
  end

  # Searches one trigger poller tick spends: one per enabled GitHub condition, capped at
  # MAX_POLLER_RESERVE. Cached briefly; a database that cannot answer reserves nothing.
  def poller_search_reserve
    Rails.cache.fetch("#{CACHE_PREFIX}:poller_search_reserve", expires_in: POLLER_RESERVE_TTL) do
      TriggerCondition.github.joins(:trigger).where(triggers: { status: "enabled" }).count
    end.to_i.clamp(0, MAX_POLLER_RESERVE)
  rescue => e
    Rails.logger.warn "[GithubRateLimit] Could not count the trigger poller's conditions (#{e.class}: #{e.message})"
    0
  end

  # Open a breaker until reset_at. Logs once per breaker, not once per call: `unless_exist`
  # makes the first writer the only one that logs. A breaker already covering reset_at is
  # left alone; one that is only still in its jitter window is replaced.
  def trip(credential, resource, reset_at, kind: :exhausted, spread: nil, why: nil)
    spread ||= REOPEN_JITTER.fetch(resource, DEFAULT_REOPEN_JITTER)
    return if reset_at <= Time.current

    key = exhausted_key(credential, resource)
    existing = read_hold(credential, resource)
    return if existing && existing[:reset_at] >= reset_at - 1

    value = { "reset" => reset_at.to_i, "spread" => spread.to_i, "kind" => kind.to_s }
    # Kept a few seconds past the last moment any caller can be held, then dropped.
    expires_in = (reset_at - Time.current) + spread + 5
    opened = Rails.cache.write(key, value, expires_in: expires_in, unless_exist: existing.nil?)
    return unless opened

    if kind == :backoff
      Rails.logger.warn "[GithubRateLimit] GitHub rate-limited #{credential[:label]}'s #{resource} budget " \
                        "(#{why}); Zimmer's #{resource} calls on that credential back off until " \
                        "#{reset_at.utc.iso8601}"
    else
      Rails.logger.warn "[GithubRateLimit] GitHub's #{resource} rate limit is spent for #{credential[:label]} " \
                        "until #{reset_at.utc.iso8601}; Zimmer's #{resource} calls on that credential are " \
                        "answered locally until then instead of being refused by GitHub"
    end
  end

  # The breaker on this credential and budget: { reset_at:, spread:, kind: }, or nil.
  # An Integer is a breaker written before the jitter existed: a reset time, kind :exhausted.
  def read_hold(credential, resource)
    value = Rails.cache.read(exhausted_key(credential, resource))
    case value
    when Integer
      { reset_at: Time.zone.at(value), spread: REOPEN_JITTER.fetch(resource, DEFAULT_REOPEN_JITTER), kind: :exhausted }
    when Hash
      { reset_at: Time.zone.at(value["reset"].to_i), spread: value["spread"].to_i,
        kind: value["kind"].to_s == "backoff" ? :backoff : :exhausted }
    end
  end

  # GitHub's reset time while it is still ahead, for the breaker on this credential and budget.
  def read_exhausted(credential, resource)
    hold = read_hold(credential, resource)
    return nil unless hold

    hold[:reset_at].future? ? hold[:reset_at] : nil
  end

  # :primary, :secondary or nil for the text of a call GitHub may have refused.
  #
  # Every status `gh` printed must be a rate-limit status, the unanimity
  # GithubSearchService#rate_limited_failure? demands, so an echoed query cannot drag a 404
  # into a breaker. A primary refusal from GraphQL carries no status at all, which is allowed.
  def rate_limit_kind(text)
    text = text.to_s
    statuses = text.scan(HTTP_STATUS_PATTERN).flatten.map(&:to_i)
    return nil unless statuses.all? { |status| RATE_LIMIT_STATUSES.include?(status) }

    return :secondary if text.match?(SECONDARY_LIMIT_PATTERN)
    return :primary if text.match?(PRIMARY_EXHAUSTION_PATTERN)
    return :secondary if statuses.any? && statuses.all?(429)

    nil
  end

  def retry_after_in(*texts)
    texts.each do |text|
      seconds = text.to_s[RETRY_AFTER_PATTERN, 1]&.to_i
      return seconds if seconds&.positive?
    end
    nil
  end

  # A float in [0, 1). Its own method so tests can pin it.
  def random
    Kernel.rand
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

  def backoff_key(credential, resource)
    "#{CACHE_PREFIX}:backoff:#{credential[:id]}:#{resource}"
  end

  def search_share_key(credential)
    "#{CACHE_PREFIX}:search_share:#{credential[:id]}"
  end

  def snapshot_key(credential)
    "#{CACHE_PREFIX}:snapshot:#{credential[:id]}"
  end
end
