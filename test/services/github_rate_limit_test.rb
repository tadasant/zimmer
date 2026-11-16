# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# GithubRateLimit is the breaker GithubCli applies before spending
# any of GitHub's budgets. The case it exists for is 2026-11-15: the REST core budget ran out,
# and Zimmer's callers sent 586 more calls in 19 minutes, every one refused and every one counted.
class GithubRateLimitTest < ActiveSupport::TestCase
  include GithubSearchStderrFixtures

  # GithubRateLimit reads GH_TOKEN and GH_TOKEN__<OWNER> from ENV, as GithubTokens does.
  # Each test sets exactly the tokens it means, and teardown puts ENV back.
  GH_VARIABLES = ->(keys) { keys.select { |key| key == "GH_TOKEN" || key.start_with?("GH_TOKEN__") } }

  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @original_env = GH_VARIABLES.call(ENV.keys).to_h { |key| [ key, ENV[key] ] }
    set_tokens("GH_TOKEN" => "ghp_default_token_for_tests")
  end

  teardown do
    Rails.cache = @original_cache
    GH_VARIABLES.call(ENV.keys).each { |key| ENV.delete(key) }
    @original_env.each { |key, value| ENV[key] = value }
  end

  def set_tokens(vars)
    GH_VARIABLES.call(ENV.keys).each { |key| ENV.delete(key) }
    vars.each { |key, value| ENV[key] = value }
  end

  def status(ok) = fake_process_status(exitstatus: ok ? 0 : 1)

  def rate_limit_json(core_remaining:, reset_at:, search_remaining: 30, graphql_remaining: 5000)
    {
      "resources" => {
        "core" => { "limit" => 5000, "remaining" => core_remaining, "reset" => reset_at.to_i },
        "search" => { "limit" => 30, "remaining" => search_remaining, "reset" => (Time.current + 60).to_i },
        "graphql" => { "limit" => 5000, "remaining" => graphql_remaining, "reset" => reset_at.to_i }
      }
    }.to_json
  end

  def probe?(command) = command == [ "gh", "api", "rate_limit" ]

  # --- which budget a call spends ---------------------------------------------------

  test "resource_for sorts gh argv into GitHub's budgets, and exempts the free probe" do
    assert_equal "core", GithubRateLimit.resource_for(%w[gh api repos/a/b/issues/1/comments])
    assert_equal "core", GithubRateLimit.resource_for(%w[gh auth status --json hosts])
    assert_equal "graphql", GithubRateLimit.resource_for(%w[gh pr view 1 --repo a/b --json state])
    assert_equal "graphql", GithubRateLimit.resource_for(%w[gh api graphql -f query=x])
    assert_equal "search", GithubRateLimit.resource_for([ "gh", "api", "-X", "GET", "search/issues", "--raw-field", "q=x" ])
    assert_nil GithubRateLimit.resource_for(%w[gh api rate_limit])
    assert_nil GithubRateLimit.resource_for(%w[gh auth token]), "local: never refused"
    assert_nil GithubRateLimit.resource_for(%w[gh --version])
    assert_equal "search", GithubRateLimit.resource_for(%w[gh search prs foo])
    assert_equal "graphql", GithubRateLimit.resource_for(%w[gh repo view a/b])
    assert_nil GithubRateLimit.resource_for(%w[git status])
  end

  # --- the breaker -------------------------------------------------------------------

  test "the first primary rate-limit refusal trips the breaker, and later calls never reach GitHub" do
    reset_at = 17.minutes.from_now
    calls = []
    BoundedSubprocess.stubs(:run).with do |command, **|
      calls << command
      true
    end.returns([ "", PRIMARY_RATE_LIMIT, status(false) ]).then
      .returns([ rate_limit_json(core_remaining: 0, reset_at: reset_at), "", status(true) ])

    first = GithubCli.run(%w[gh api repos/tadasant/zimmer/issues/1/comments], timeout: 5)
    refute first.success?
    refute first.refused?, "the call that met the limit was really sent"
    assert_equal [ %w[gh api repos/tadasant/zimmer/issues/1/comments], %w[gh api rate_limit] ], calls

    BoundedSubprocess.expects(:run).never
    second = GithubCli.run(%w[gh api repos/tadasant/zimmer/pulls/2], timeout: 5)

    assert second.refused?
    refute second.success?
    assert_nil second.exit_code, "a refused call has no exit code to read meaning into"
    assert_equal "core", second.refusal.resource
    assert_equal reset_at.to_i, second.refusal.reset_at.to_i
    assert_includes second.failure_description, "not sent to GitHub"
    assert_includes second.failure_description, reset_at.utc.iso8601
    refute_includes second.failure_description, "ghp_", "the token never appears in a message"
  end

  test "a spent core budget does not stop the search budget the trigger poller spends" do
    reset_at = 10.minutes.from_now
    BoundedSubprocess.stubs(:run).returns([ "", PRIMARY_RATE_LIMIT, status(false) ]).then
      .returns([ rate_limit_json(core_remaining: 0, reset_at: reset_at), "", status(true) ])
    GithubCli.run(%w[gh api repos/a/b], timeout: 5)

    assert GithubRateLimit.refusal_for(%w[gh api repos/a/b])
    assert_nil GithubRateLimit.refusal_for([ "gh", "api", "-X", "GET", "search/issues" ]),
               "search has its own budget; the poller's sweep must keep running"
    assert_nil GithubRateLimit.refusal_for(%w[gh pr view 1 --repo a/b]),
               "graphql still had budget in the probe"
  end

  test "the breaker reopens inside GitHub's reset plus the jitter window, never before reset" do
    reset_at = 5.minutes.from_now
    BoundedSubprocess.stubs(:run).returns([ "", PRIMARY_RATE_LIMIT, status(false) ]).then
      .returns([ rate_limit_json(core_remaining: 0, reset_at: reset_at), "", status(true) ])
    GithubCli.run(%w[gh api repos/a/b], timeout: 5)
    assert GithubRateLimit.refusal_for(%w[gh api repos/a/b])

    jitter = GithubRateLimit::REOPEN_JITTER.fetch("core")
    travel_to(reset_at + 1.second) do
      GithubRateLimit.stubs(:random).returns(0.0)
      assert_nil GithubRateLimit.refusal_for(%w[gh api repos/a/b]), "a call that drew no jitter goes at reset"

      GithubRateLimit.stubs(:random).returns(0.99)
      refusal = GithubRateLimit.refusal_for(%w[gh api repos/a/b])
      assert refusal, "a call that drew most of the window is still held"
      assert_equal reset_at.to_i, refusal.reset_at.to_i, "reset_at stays GitHub's reset"
      assert_in_delta reset_at + (0.99 * jitter), refusal.retry_at, 1
    end

    travel_to(reset_at + jitter + 1) do
      GithubRateLimit.stubs(:random).returns(0.99)
      assert_nil GithubRateLimit.refusal_for(%w[gh api repos/a/b]), "nobody is held past the window"
    end
  end

  test "each call draws its own reopen time, so the callers behind one breaker do not return together" do
    reset_at = 5.minutes.from_now
    GithubRateLimit.trip(GithubRateLimit.credential_for({}), "core", reset_at)
    GithubRateLimit.stubs(:random).returns(0.1).then.returns(0.5).then.returns(0.9)

    retry_ats = 3.times.map { GithubRateLimit.refusal_for(%w[gh api repos/a/b]).retry_at }

    assert_equal 3, retry_ats.uniq.size
    jitter = GithubRateLimit::REOPEN_JITTER.fetch("core")
    retry_ats.each { |retry_at| assert_operator retry_at, :>=, reset_at.change(usec: 0) }
    retry_ats.each { |retry_at| assert_operator retry_at, :<=, reset_at + jitter }
  end

  test "the search breaker's jitter is a few seconds, since its window is a minute" do
    reset_at = 40.seconds.from_now
    GithubRateLimit.trip(GithubRateLimit.credential_for({}), "search", reset_at)
    GithubRateLimit.stubs(:random).returns(1.0)

    refusal = GithubRateLimit.refusal_for([ "gh", "api", "-X", "GET", "search/issues" ])
    assert_in_delta reset_at + GithubRateLimit::REOPEN_JITTER.fetch("search"), refusal.retry_at, 1
    assert_operator GithubRateLimit::REOPEN_JITTER.fetch("search"), :<, 10
  end

  test "a breaker written before the jitter existed (a bare reset time) is still read" do
    credential = GithubRateLimit.credential_for({})
    reset_at = 7.minutes.from_now
    Rails.cache.write(GithubRateLimit.exhausted_key(credential, "core"), reset_at.to_i)

    refusal = GithubRateLimit.refusal_for(%w[gh api repos/a/b])
    assert_equal :exhausted, refusal.kind
    assert_equal reset_at.to_i, refusal.reset_at.to_i
  end

  test "a secondary rate limit backs off: at least GitHub's minute, and nothing is sent meanwhile" do
    GithubRateLimit.stubs(:random).returns(0.5)
    BoundedSubprocess.stubs(:run).returns([ "", SECONDARY_RATE_LIMIT, status(false) ])
    GithubCli.run(%w[gh api repos/a/b], timeout: 5)

    refusal = GithubRateLimit.refusal_for(%w[gh api repos/a/b])
    assert_equal :backoff, refusal.kind
    hold = GithubRateLimit::SECONDARY_FLOOR + (0.5 * GithubRateLimit::BACKOFF_BASE)
    assert_in_delta hold.seconds.from_now, refusal.retry_at, 2
    assert_includes refusal.message, "backing off"

    BoundedSubprocess.unstub(:run)
    BoundedSubprocess.expects(:run).never
    assert GithubCli.run(%w[gh api repos/a/c], timeout: 5).refused?
    assert_nil GithubRateLimit.refusal_for([ "gh", "api", "-X", "GET", "search/issues" ]),
               "a burst limit on core holds core only"
  end

  test "concurrent refusals of one limit count as one step, not one each" do
    GithubRateLimit.stubs(:random).returns(1.0)
    BoundedSubprocess.stubs(:run).returns([ "", SECONDARY_RATE_LIMIT, status(false) ])
    # Several calls were already in flight when the limit hit; each comes back refused.
    3.times { GithubRateLimit.observe(%w[gh api repos/a/b], SECONDARY_RATE_LIMIT) }

    refusal = GithubRateLimit.refusal_for(%w[gh api repos/a/b])
    assert_in_delta (GithubRateLimit::SECONDARY_FLOOR + GithubRateLimit::BACKOFF_BASE).seconds.from_now,
                    refusal.retry_at, 2
  end

  test "only a served call resets the backoff: a 404, a dropped connection or a refusal on stdout do not" do
    GithubRateLimit.stubs(:random).returns(1.0)
    credential = GithubRateLimit.credential_for({})
    key = GithubRateLimit.backoff_key(credential, "core")
    2.times { GithubRateLimit.bump_backoff(credential, "core") }

    GithubRateLimit.observe(%w[gh api repos/a/b], "gh: Not Found (HTTP 404)")
    GithubRateLimit.observe(%w[gh api repos/a/b], "dial tcp: lookup api.github.com: no such host")
    # `gh auth status --json` exits 0 with GitHub's refusal in its JSON.
    GithubRateLimit.observe(%w[gh auth status --json hosts], "",
                            stdout: '{"hosts":{"github.com":[{"error":"API rate limit exceeded for user ID 1."}]}}')
    assert_equal 2, Rails.cache.read(key, raw: true).to_i

    GithubRateLimit.observe(%w[gh api repos/a/b], "", stdout: "{}")
    assert_nil Rails.cache.read(key, raw: true)
  end

  test "a bare 429 is a secondary limit; a rate-limit sentence beside a 404 is not a limit at all" do
    BoundedSubprocess.stubs(:run).returns([ "", "gh: Too Many Requests (HTTP 429)", status(false) ])
    GithubCli.run(%w[gh api repos/a/b], timeout: 5)
    assert_equal :backoff, GithubRateLimit.refusal_for(%w[gh api repos/a/b]).kind

    Rails.cache.clear
    echoed = "gh: Not Found: You have exceeded a secondary rate limit (HTTP 404)"
    BoundedSubprocess.stubs(:run).returns([ "", echoed, status(false) ])
    GithubCli.run(%w[gh api repos/a/b], timeout: 5)
    assert_nil GithubRateLimit.refusal_for(%w[gh api repos/a/b])
  end

  test "repeated rate limits back off exponentially to the cap, and the first served call resets it" do
    travel_to(Time.current.change(usec: 0))
    GithubRateLimit.stubs(:random).returns(1.0)
    floor = GithubRateLimit::SECONDARY_FLOOR
    base = GithubRateLimit::BACKOFF_BASE
    cap = GithubRateLimit::BACKOFF_CAP
    holds = []

    7.times do
      BoundedSubprocess.stubs(:run).returns([ "", SECONDARY_RATE_LIMIT, status(false) ])
      GithubCli.run(%w[gh api repos/a/b], timeout: 5)
      refusal = GithubRateLimit.refusal_for(%w[gh api repos/a/b])
      holds << (refusal.retry_at - Time.current).round
      travel_to(refusal.retry_at + 1)
    end

    expected = (1..7).map { |n| floor + [ cap, base * (2**(n - 1)) ].min }
    assert_equal expected, holds
    assert_equal floor + cap, holds.last, "capped"

    # GitHub serves the next call; the run of backoffs is over.
    BoundedSubprocess.stubs(:run).returns([ "{}", "", status(true) ])
    GithubCli.run(%w[gh api repos/a/b], timeout: 5)
    BoundedSubprocess.stubs(:run).returns([ "", SECONDARY_RATE_LIMIT, status(false) ])
    GithubCli.run(%w[gh api repos/a/b], timeout: 5)
    refusal = GithubRateLimit.refusal_for(%w[gh api repos/a/b])
    assert_equal floor + base, (refusal.retry_at - Time.current).round, "back to the first step"
  ensure
    travel_back
  end

  test "full jitter: the hold is drawn from the whole window above the floor" do
    BoundedSubprocess.stubs(:run).returns([ "", SECONDARY_RATE_LIMIT, status(false) ])
    GithubRateLimit.stubs(:random).returns(0.0)
    GithubCli.run(%w[gh api repos/a/b], timeout: 5)
    low = GithubRateLimit.refusal_for(%w[gh api repos/a/b]).retry_at - Time.current

    Rails.cache.clear
    GithubRateLimit.stubs(:random).returns(0.75)
    GithubCli.run(%w[gh api repos/a/b], timeout: 5)
    high = GithubRateLimit.refusal_for(%w[gh api repos/a/b]).retry_at - Time.current

    assert_in_delta GithubRateLimit::SECONDARY_FLOOR, low, 1
    assert_in_delta GithubRateLimit::SECONDARY_FLOOR + (0.75 * GithubRateLimit::BACKOFF_BASE), high, 1
  end

  test "a primary refusal the probe contradicts holds on the backoff, briefly at first" do
    GithubRateLimit.stubs(:random).returns(0.5)
    BoundedSubprocess.stubs(:run).returns([ "", PRIMARY_RATE_LIMIT, status(false) ]).then
      .returns([ rate_limit_json(core_remaining: 4000, reset_at: 30.minutes.from_now), "", status(true) ])
    GithubCli.run(%w[gh api repos/a/b], timeout: 5)

    refusal = GithubRateLimit.refusal_for(%w[gh api repos/a/b])
    assert_equal :backoff, refusal.kind
    hold = GithubRateLimit::UNDATED_FLOOR + (0.5 * GithubRateLimit::BACKOFF_BASE)
    assert_in_delta hold.seconds.from_now, refusal.retry_at, 2
  end

  test "a refusal again right after the breaker reopens, with the probe showing the old window, backs off" do
    reset_at = 2.minutes.from_now
    BoundedSubprocess.stubs(:run).returns([ "", PRIMARY_RATE_LIMIT, status(false) ]).then
      .returns([ rate_limit_json(core_remaining: 0, reset_at: reset_at), "", status(true) ])
    GithubCli.run(%w[gh api repos/a/b], timeout: 5)

    travel_to(reset_at + GithubRateLimit::REOPEN_JITTER.fetch("core") + 1) do
      GithubRateLimit.stubs(:random).returns(1.0)
      # GitHub still refuses, and its probe still reports the window that just passed.
      BoundedSubprocess.stubs(:run).returns([ "", PRIMARY_RATE_LIMIT, status(false) ]).then
        .returns([ rate_limit_json(core_remaining: 0, reset_at: reset_at), "", status(true) ])
      GithubCli.run(%w[gh api repos/a/b], timeout: 5)

      refusal = GithubRateLimit.refusal_for(%w[gh api repos/a/b])
      assert_equal :backoff, refusal.kind, "not let through to be refused call after call"
      assert_in_delta (GithubRateLimit::UNDATED_FLOOR + GithubRateLimit::BACKOFF_BASE).seconds.from_now,
                      refusal.retry_at, 2
    end
  end

  test "when the probe fails too, the breaker backs off, growing with each failure" do
    GithubRateLimit.stubs(:random).returns(1.0)
    BoundedSubprocess.stubs(:run).returns([ "", PRIMARY_RATE_LIMIT, status(false) ])
    GithubCli.run(%w[gh api repos/a/b], timeout: 5)

    first = GithubRateLimit.refusal_for(%w[gh api repos/a/b])
    assert_equal :backoff, first.kind
    assert_in_delta (GithubRateLimit::UNDATED_FLOOR + GithubRateLimit::BACKOFF_BASE).seconds.from_now, first.retry_at, 2

    travel_to(first.retry_at + 1) do
      GithubCli.run(%w[gh api repos/a/b], timeout: 5)
      second = GithubRateLimit.refusal_for(%w[gh api repos/a/b])
      assert_in_delta (GithubRateLimit::UNDATED_FLOOR + (2 * GithubRateLimit::BACKOFF_BASE)).seconds.from_now,
                      second.retry_at, 2
    end
  end

  test "breakers are per credential: one owner's spent token does not stop another's" do
    set_tokens("GH_TOKEN" => "ghp_default_token_for_tests", "GH_TOKEN__PULSEMCP" => "ghp_pulsemcp_token")
    BoundedSubprocess.stubs(:run).returns([ "", PRIMARY_RATE_LIMIT, status(false) ]).then
      .returns([ rate_limit_json(core_remaining: 0, reset_at: 20.minutes.from_now), "", status(true) ])

    GithubCli.run(%w[gh api repos/pulsemcp/x/pulls/1], timeout: 5)

    refusal = GithubRateLimit.refusal_for(%w[gh api repos/pulsemcp/x], env: { "GH_TOKEN" => "ghp_pulsemcp_token" })
    assert refusal
    assert_equal "GH_TOKEN__PULSEMCP", refusal.credential
    assert_nil GithubRateLimit.refusal_for(%w[gh api repos/tadasant/zimmer]),
               "the default token's budget was never spent"
  end

  test "the breaker logs once when it opens, not once per refused call" do
    BoundedSubprocess.stubs(:run).returns([ "", PRIMARY_RATE_LIMIT, status(false) ]).then
      .returns([ rate_limit_json(core_remaining: 0, reset_at: 20.minutes.from_now), "", status(true) ])

    entries = capture_log_entries do
      GithubCli.run(%w[gh api repos/a/b], timeout: 5)
      5.times { GithubCli.run(%w[gh api repos/a/b], timeout: 5) }
    end

    opened = entries.select { |_severity, message| message.include?("[GithubRateLimit] GitHub's core rate limit is spent") }
    assert_equal 1, opened.size
    assert_equal "WARN", opened.first.first
  end

  test "a cache that raises lets the call through" do
    Rails.cache.stubs(:read).raises(RuntimeError, "cache down")

    assert_nil GithubRateLimit.refusal_for(%w[gh api repos/a/b])
  end

  test "a GithubCli call for an owner is refused by that owner's breaker, not the default token's" do
    set_tokens("GH_TOKEN" => "ghp_default_token_for_tests", "GH_TOKEN__PULSEMCP" => "ghp_pulsemcp_token")
    BoundedSubprocess.stubs(:run).returns([ "", PRIMARY_RATE_LIMIT, status(false) ]).then
      .returns([ rate_limit_json(core_remaining: 0, reset_at: 20.minutes.from_now), "", status(true) ])
    GithubCli.run(%w[gh api repos/pulsemcp/x/pulls/1], timeout: 5)

    BoundedSubprocess.unstub(:run)
    BoundedSubprocess.expects(:run).never
    assert GithubCli.run(%w[gh api repos/pulsemcp/y/pulls/2], timeout: 5).refused?

    BoundedSubprocess.unstub(:run)
    BoundedSubprocess.expects(:run).once.returns([ "{}", "", status(true) ])
    refute GithubCli.run(%w[gh api repos/tadasant/zimmer/pulls/3], timeout: 5).refused?,
           "the default token's budget was never spent"
  end

  test "a budget with calls left is never refused, however low" do
    BoundedSubprocess.stubs(:run).returns(
      [ rate_limit_json(core_remaining: 3, reset_at: 25.minutes.from_now), "", status(true) ]
    )
    GithubRateLimitSnapshotJob.perform_now

    assert_nil GithubRateLimit.refusal_for(%w[gh api repos/a/b])
    assert_includes GithubRateLimit.diagnosis, "GH_TOKEN's core budget is down to 3/5000",
                    "but the page names it, so a stall just before exhaustion still says why"
  end

  test "a snapshot that has aged out is not reported" do
    BoundedSubprocess.stubs(:run).returns(
      [ rate_limit_json(core_remaining: 10, reset_at: 50.minutes.from_now), "", status(true) ]
    )
    GithubRateLimitSnapshotJob.perform_now

    travel_to(GithubRateLimit::SNAPSHOT_TTL.from_now + 1.second) do
      assert_nil GithubRateLimit.diagnosis
    end
  end

  test "the snapshot job trips the breaker on a budget that is already spent" do
    BoundedSubprocess.stubs(:run).returns(
      [ rate_limit_json(core_remaining: 0, reset_at: 9.minutes.from_now), "", status(true) ]
    )
    GithubRateLimitSnapshotJob.perform_now

    refusal = GithubRateLimit.refusal_for(%w[gh auth status --json hosts])
    assert_equal "core", refusal.resource, "known spent before any caller was refused"
  end

  # --- the diagnosis -----------------------------------------------------------------

  test "diagnosis names a spent budget and its reset, and is nil when nothing is known" do
    assert_nil GithubRateLimit.diagnosis

    reset_at = 12.minutes.from_now
    BoundedSubprocess.stubs(:run).returns(
      [ rate_limit_json(core_remaining: 0, reset_at: reset_at), "", status(true) ]
    )
    GithubRateLimitSnapshotJob.perform_now

    diagnosis = GithubRateLimit.diagnosis
    assert_includes diagnosis, "GH_TOKEN's core budget is spent until #{reset_at.utc.iso8601}"
    assert_includes diagnosis, "agent sessions running `gh` as the same user"
  end

  # --- the trigger poller's share of the search budget --------------------------------

  SEARCH = [ "gh", "api", "-X", "GET", "search/issues", "--raw-field", "q=x" ].freeze

  test "searches outside the poller stop where the poller's reserve begins; the poller's do not" do
    BoundedSubprocess.stubs(:run).returns([ "{}", "", status(true) ])
    GithubRateLimit.stubs(:poller_search_reserve).returns(8)
    share = GithubRateLimit::SEARCH_BUDGET - 8

    share.times { refute GithubCli.run(SEARCH, timeout: 5).refused? }
    over = GithubCli.run(SEARCH, timeout: 5)
    assert over.refused?
    assert_equal :share, over.refusal.kind
    assert_includes over.failure_description, "outside the trigger poller"

    GithubRateLimit.on_poller_budget do
      8.times { refute GithubCli.run(SEARCH, timeout: 5).refused?, "the poller is never held to the share" }
    end
    refute GithubRateLimit.on_poller_budget?, "the flag does not outlive the block"
    assert GithubCli.run(SEARCH, timeout: 5).refused?

    refute GithubCli.run(%w[gh api repos/a/b], timeout: 5).refused?, "the share is for search only"

    travel_to((GithubRateLimit::SEARCH_WINDOW + 1).seconds.from_now) do
      refute GithubCli.run(SEARCH, timeout: 5).refused?, "a new window, a new share"
    end
  end

  test "the poller's reserve is one search per enabled GitHub condition, capped at half the budget" do
    enabled = TriggerCondition.github.joins(:trigger).where(triggers: { status: "enabled" }).count
    assert_equal enabled.clamp(0, GithubRateLimit::MAX_POLLER_RESERVE), GithubRateLimit.poller_search_reserve

    Rails.cache.clear
    TriggerCondition.stubs(:github).raises(ActiveRecord::ConnectionNotEstablished)
    assert_equal 0, GithubRateLimit.poller_search_reserve, "a database that cannot answer reserves nothing"

    Rails.cache.clear
    TriggerCondition.unstub(:github)
    Rails.cache.write("github_rate_limit:poller_search_reserve", 99)
    assert_equal GithubRateLimit::MAX_POLLER_RESERVE, GithubRateLimit.poller_search_reserve
    assert_operator GithubRateLimit::SEARCH_BUDGET - GithubRateLimit::MAX_POLLER_RESERVE, :>=, GithubRateLimit::SEARCH_BUDGET / 2
  end

  test "the poller job's sweep runs on the poller's budget" do
    seen = nil
    GithubTriggerPollerJob.any_instance.stubs(:perform).with { seen = GithubRateLimit.on_poller_budget?; true }
    GithubTriggerPollerJob.perform_now

    assert seen
    refute GithubRateLimit.on_poller_budget?
  end

  test "a cache that cannot count lets a search through" do
    Rails.cache.stubs(:increment).raises(RuntimeError, "cache down")
    assert_nil GithubRateLimit.admit(SEARCH)
  end

  # --- what a status surface can read -------------------------------------------------

  test "holds names each open breaker and the latest moment any caller is held back" do
    assert_equal [], GithubRateLimit.holds

    reset_at = 9.minutes.from_now
    GithubRateLimit.trip(GithubRateLimit.credential_for({}), "core", reset_at)

    hold = GithubRateLimit.holds.sole
    assert_equal "GH_TOKEN", hold[:credential]
    assert_equal "core", hold[:resource]
    assert_equal :exhausted, hold[:kind]
    assert_equal reset_at.to_i, hold[:reset_at].to_i
    assert_equal reset_at.to_i + GithubRateLimit::REOPEN_JITTER.fetch("core"), hold[:retry_by].to_i
  end
end
