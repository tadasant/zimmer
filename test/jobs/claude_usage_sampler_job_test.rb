# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The sampler feeds `ClaudeAccountPool`, which is the number the spot gate
# decides on — so what it does and does not probe each tick IS the freshness
# guarantee. These tests pin down the three things #501 asked for: spares get
# sampled, the serving account is never starved to make room for them, and one
# account's probe failing costs only that account its reading.
class ClaudeUsageSamplerJobTest < ActiveSupport::TestCase
  setup do
    ClaudeAccountQuotaSnapshot.delete_all
    ClaudeAccount.delete_all
    @probed_tokens = []
  end

  # --- The serving account ---------------------------------------------------

  test "samples the serving account every tick, however fresh its reading" do
    serving = account("serving@example.com", current: true)
    seed(serving, read_at: 1.minute.ago)
    stub_probe

    ClaudeUsageSamplerJob.perform_now

    assert_equal 1, sampled(serving), "the serving account is the hot path — it is probed unconditionally"
    assert_includes @probed_tokens, token_for(serving)
  end

  test "falls back to the highest-priority available account when none is current" do
    first = account("first@example.com", priority: 0)
    second = account("second@example.com", priority: 1)
    seed(first, read_at: 1.minute.ago)
    seed(second, read_at: 1.minute.ago)
    stub_probe

    ClaudeUsageSamplerJob.perform_now

    assert_equal 1, sampled(first)
    assert_equal 0, sampled(second), "a fresh spare is not worth a probe"
  end

  test "the serving account is never probed twice in one tick" do
    serving = account("serving@example.com", current: true)
    seed(serving, read_at: 3.hours.ago)
    stub_probe

    ClaudeUsageSamplerJob.perform_now

    assert_equal 1, sampled(serving), "a stale serving account is still only one probe"
  end

  test "a pool with nothing serving still refreshes its stale spares" do
    spare = account("spare@example.com", status: :quota_exceeded)
    seed(spare, read_at: 3.hours.ago)
    stub_probe

    ClaudeUsageSamplerJob.perform_now

    assert_equal 1, sampled(spare)
  end

  # --- Spares ----------------------------------------------------------------

  test "samples a spare whose reading has aged past the staleness bound" do
    serving = account("serving@example.com", current: true)
    spare = account("spare@example.com")
    seed(serving, read_at: 1.minute.ago)
    seed(spare, read_at: (ClaudeUsageSamplerJob::SPARE_MAX_STALENESS + 5.minutes).ago)
    stub_probe

    ClaudeUsageSamplerJob.perform_now

    assert_equal 1, sampled(spare), "a stale spare is a load-bearing term in the pool average"
  end

  test "leaves a spare whose reading is still inside the bound alone" do
    serving = account("serving@example.com", current: true)
    spare = account("spare@example.com")
    seed(serving, read_at: 1.minute.ago)
    seed(spare, read_at: (ClaudeUsageSamplerJob::SPARE_MAX_STALENESS - 5.minutes).ago)
    stub_probe

    ClaudeUsageSamplerJob.perform_now

    assert_equal 0, sampled(spare), "the whole point of sampling on staleness is not re-probing fresh accounts"
    assert_equal [ token_for(serving) ], @probed_tokens
  end

  test "a spare that has never been sampled is the stalest thing there is" do
    serving = account("serving@example.com", current: true)
    never_read = account("never@example.com")
    old = account("old@example.com")
    seed(serving, read_at: 1.minute.ago)
    seed(old, read_at: 3.hours.ago)
    stub_probe

    with_spare_cap(1) { ClaudeUsageSamplerJob.perform_now }

    assert_equal 1, sampled(never_read), "an account with no reading contributes nothing to the average"
    assert_equal 0, sampled(old)
  end

  test "stale spares are probed oldest reading first" do
    serving = account("serving@example.com", current: true)
    oldest = account("oldest@example.com")
    middle = account("middle@example.com")
    newest = account("newest@example.com")
    seed(serving, read_at: 1.minute.ago)
    seed(oldest, read_at: 6.hours.ago)
    seed(middle, read_at: 4.hours.ago)
    seed(newest, read_at: 2.hours.ago)
    stub_probe

    ClaudeUsageSamplerJob.perform_now

    assert_equal 1, sampled(oldest)
    assert_equal 1, sampled(middle)
    assert_equal 0, sampled(newest), "the per-tick cap defers the least stale spare to the next tick"
  end

  test "the per-tick cap bounds how many probes one tick can fire" do
    serving = account("serving@example.com", current: true)
    seed(serving, read_at: 1.minute.ago)
    spares = 4.times.map { |i| account("spare#{i}@example.com").tap { |a| seed(a, read_at: (3 + i).hours.ago) } }
    stub_probe

    with_spare_cap(2) { ClaudeUsageSamplerJob.perform_now }

    assert_equal 3, @probed_tokens.size, "one serving probe plus the cap"
    assert_equal 2, spares.count { |spare| sampled(spare) == 1 }
  end

  # --- Accounts that cannot be probed ----------------------------------------

  test "an account awaiting re-authentication is skipped without a probe" do
    serving = account("serving@example.com", current: true)
    reauth = account("reauth@example.com", status: :needs_reauth)
    seed(serving, read_at: 1.minute.ago)
    seed(reauth, read_at: 3.hours.ago)
    stub_probe

    ClaudeUsageSamplerJob.perform_now

    assert_equal 0, sampled(reauth)
    assert_equal [ token_for(serving) ], @probed_tokens
  end

  # The starvation this guards: an account Zimmer cannot authenticate as never
  # gets a fresh reading, so it is permanently the stalest thing in the pool. If
  # it were allowed into the ordering it would take a slot under the cap every
  # single tick, and the spares that CAN be read would never be reached.
  test "an unprobeable account does not hold a slot the readable spares need" do
    serving = account("serving@example.com", current: true)
    account("reauth@example.com", status: :needs_reauth) # never read, permanently stale
    readable = account("readable@example.com")
    seed(serving, read_at: 1.minute.ago)
    seed(readable, read_at: 3.hours.ago)
    stub_probe

    with_spare_cap(1) { ClaudeUsageSamplerJob.perform_now }

    assert_equal 1, sampled(readable)
  end

  test "an account with an expired token and nothing to refresh with is skipped" do
    serving = account("serving@example.com", current: true)
    dead = account("dead@example.com", expires_at: 1.hour.ago, refresh_token: nil)
    seed(serving, read_at: 1.minute.ago)
    seed(dead, read_at: 3.hours.ago)
    stub_probe

    ClaudeUsageSamplerJob.perform_now

    assert_equal 0, sampled(dead)
    assert_equal [ token_for(serving) ], @probed_tokens
  end

  test "another runtime's accounts are not probed for Anthropic quota" do
    serving = account("serving@example.com", current: true)
    codex = ClaudeAccount.create!(email: "codex@example.com", runtime: "codex", priority: 9,
      oauth_config: { "auth_json" => { "tokens" => { "access_token" => "codex-token" } } })
    seed(serving, read_at: 1.minute.ago)
    seed(codex, read_at: 3.hours.ago)
    stub_probe

    ClaudeUsageSamplerJob.perform_now

    assert_equal 0, sampled(codex)
  end

  # --- Failure isolation -----------------------------------------------------

  test "a refused probe on one account does not cost the others their reading" do
    serving = account("serving@example.com", current: true)
    broken = account("broken@example.com")
    healthy = account("healthy@example.com")
    seed(serving, read_at: 1.minute.ago)
    seed(broken, read_at: 6.hours.ago)
    seed(healthy, read_at: 3.hours.ago)
    stub_probe
    QuotaCheckService.stubs(:check_with_token).with(token_for(broken)).returns(
      QuotaCheckService::Result.new(success: false, error_message: "401 Unauthorized")
    )

    ClaudeUsageSamplerJob.perform_now

    assert_equal 0, sampled(broken)
    assert_equal 1, sampled(serving)
    assert_equal 1, sampled(healthy), "the account probed after the failure still got its reading"
  end

  test "a probe that raises on one account does not stop the sweep" do
    serving = account("serving@example.com", current: true)
    exploding = account("exploding@example.com")
    healthy = account("healthy@example.com")
    seed(serving, read_at: 1.minute.ago)
    seed(exploding, read_at: 6.hours.ago)
    seed(healthy, read_at: 3.hours.ago)
    stub_probe
    QuotaCheckService.stubs(:check_with_token).with(token_for(exploding)).raises(Errno::ECONNREFUSED)

    assert_nothing_raised { ClaudeUsageSamplerJob.perform_now }

    assert_equal 0, sampled(exploding)
    assert_equal 1, sampled(healthy)
  end

  test "the serving account failing does not stop the spares being sampled" do
    serving = account("serving@example.com", current: true)
    spare = account("spare@example.com")
    seed(serving, read_at: 1.minute.ago)
    seed(spare, read_at: 3.hours.ago)
    stub_probe
    QuotaCheckService.stubs(:check_with_token).with(token_for(serving)).raises(Errno::ETIMEDOUT)

    ClaudeUsageSamplerJob.perform_now

    assert_equal 0, sampled(serving)
    assert_equal 1, sampled(spare)
  end

  # --- Helpers ---------------------------------------------------------------

  private

  def account(email, status: :active, current: false, priority: 0,
    expires_at: 2.hours.from_now, refresh_token: "refresh")
    ClaudeAccount.create!(
      email: email, runtime: "claude_code", status: status, is_current: current, priority: priority,
      oauth_config: {
        "claude_json" => { "oauthAccount" => email },
        "credentials_json" => {
          "claudeAiOauth" => {
            "accessToken" => "token-#{email}",
            "refreshToken" => refresh_token,
            "expiresAt" => (expires_at.to_f * 1000).to_i
          }.compact
        }
      }
    )
  end

  def token_for(account) = "token-#{account.email}"

  # A prior reading on file, aged so the job's staleness test has something to
  # decide on. Written with a trigger other than the job's own, so `sampled`
  # counts only what this tick wrote.
  def seed(account, read_at:)
    ClaudeAccountQuotaSnapshot.create!(
      claude_account: account, utilization_5h: 0.4, utilization_7d: 0.3,
      reset_5h: 2.hours.from_now, reset_7d: 2.days.from_now, trigger: "page_view"
    ).tap { |snapshot| snapshot.update_columns(created_at: read_at, updated_at: read_at) }
  end

  # Readings this tick wrote, per account.
  def sampled(account) = account.quota_snapshots.where(trigger: "usage_sample").count

  def stub_probe
    QuotaCheckService.stubs(:check_with_token).with do |token|
      @probed_tokens << token
      true
    end.returns(
      QuotaCheckService::Result.new(
        success: true, subscription_type: "claude_max", utilization_5h: 0.5, utilization_7d: 0.2,
        status_5h: "allowed", status_7d: "allowed",
        reset_5h: 2.hours.from_now, reset_7d: 2.days.from_now
      )
    )
  end

  def with_spare_cap(cap)
    original = ClaudeUsageSamplerJob::MAX_SPARE_PROBES_PER_TICK
    ClaudeUsageSamplerJob.send(:remove_const, :MAX_SPARE_PROBES_PER_TICK)
    ClaudeUsageSamplerJob.const_set(:MAX_SPARE_PROBES_PER_TICK, cap)
    yield
  ensure
    ClaudeUsageSamplerJob.send(:remove_const, :MAX_SPARE_PROBES_PER_TICK)
    ClaudeUsageSamplerJob.const_set(:MAX_SPARE_PROBES_PER_TICK, original)
  end
end
