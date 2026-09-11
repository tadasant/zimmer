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

  # --- The attempt budget ----------------------------------------------------

  # The starvation a success-only budget would restore: a probe that fails writes
  # no snapshot, so the account stays exactly as stale and is back at the head of
  # the ordering next tick, and every tick after that.
  test "a spare that refuses does not hold a slot the readable spares need" do
    serving = account("serving@example.com", current: true)
    refusing = account("refusing@example.com")
    first = account("first@example.com")
    second = account("second@example.com")
    third = account("third@example.com")
    seed(serving, read_at: 1.minute.ago)
    seed(refusing, read_at: 6.hours.ago)
    seed(first, read_at: 5.hours.ago)
    seed(second, read_at: 4.hours.ago)
    seed(third, read_at: 3.hours.ago)
    stub_probe
    QuotaCheckService.stubs(:check_with_token).with(token_for(refusing)).returns(
      QuotaCheckService::Result.new(success: false, error_message: "401 Unauthorized")
    )

    ClaudeUsageSamplerJob.perform_now

    assert_equal 0, sampled(refusing)
    assert_equal 1, sampled(first), "the sweep walked past the refusal in the same tick"
    assert_equal 1, sampled(second), "and still landed a full success budget"
    assert_equal 0, sampled(third), "the success budget, not the attempt budget, is what stops it"
  end

  test "the attempt budget stops a tick that is only finding refusals" do
    serving = account("serving@example.com", current: true)
    seed(serving, read_at: 1.minute.ago)
    refusing = 5.times.map { |i| account("refusing#{i}@example.com").tap { |a| seed(a, read_at: (10 - i).hours.ago) } }
    healthy = account("healthy@example.com")
    seed(healthy, read_at: 2.hours.ago)
    stub_probe
    refusing.each do |a|
      QuotaCheckService.stubs(:check_with_token).with(token_for(a)).returns(
        QuotaCheckService::Result.new(success: false, error_message: "401 Unauthorized")
      )
    end

    ClaudeUsageSamplerJob.perform_now

    assert_equal 5, @probed_tokens.size, "one serving probe plus the attempt budget of four"
    assert_equal 0, sampled(healthy), "a tick spending its whole budget on refusals reaches no further"
    assert_equal 0, refusing.sum { |a| sampled(a) }
  end

  # --- Token refresh ---------------------------------------------------------

  test "a spare whose token is expiring soon is refreshed before it is probed" do
    serving = account("serving@example.com", current: true)
    spare = account("spare@example.com", expires_at: 5.minutes.from_now)
    seed(serving, read_at: 1.minute.ago)
    seed(spare, read_at: 3.hours.ago)
    stub_probe
    ClaudeAccount.any_instance.expects(:refresh_token!).once.returns(true)

    ClaudeUsageSamplerJob.perform_now

    assert_equal 1, sampled(spare)
  end

  test "a spare whose token refresh fails is skipped without a probe" do
    serving = account("serving@example.com", current: true)
    spare = account("spare@example.com", expires_at: 5.minutes.from_now)
    seed(serving, read_at: 1.minute.ago)
    seed(spare, read_at: 3.hours.ago)
    stub_probe
    ClaudeAccount.any_instance.stubs(:refresh_token!).returns(false)

    ClaudeUsageSamplerJob.perform_now

    assert_equal 0, sampled(spare)
    assert_equal [ token_for(serving) ], @probed_tokens, "a failed refresh costs no Anthropic probe"
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

  # The generic probe stub, doubling as a spy. Mocha collects matching
  # expectations rather than short-circuiting, so this block runs on EVERY call —
  # including calls a more specific `.with(token)` stub defined afterwards goes
  # on to answer. `@probed_tokens` is therefore every probe attempted, failures
  # included, which is what the attempt-budget assertions want.
  # --- The credential verdict (#239) -----------------------------------------
  #
  # This sweep is the pool's most regular probe, so it is the most regular source
  # of truth about whether a stored token still works.

  test "a landed sample records that Anthropic honoured the stored token" do
    serving = account("serving@example.com", current: true)
    stub_probe

    ClaudeUsageSamplerJob.perform_now

    assert_equal :verified, serving.reload.credential_state
  end

  test "a 401 takes the account out of the pool; an unreachable Anthropic does not" do
    serving = account("serving@example.com", current: true)
    ClaudeAccount.any_instance.stubs(:refresh_token!).returns(false)
    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(success: false, unreachable: false, status_code: 401,
        error_message: "No rate-limit headers in response (HTTP 401).")
    )

    ClaudeUsageSamplerJob.perform_now

    assert_equal :rejected, serving.reload.credential_state
    assert_not ClaudeAccount.any_serviceable_for?(ClaudeAuthProvider::RUNTIME)

    QuotaCheckService.unstub(:check_with_token)
    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(success: false, unreachable: true, error_message: "timed out")
    )

    ClaudeUsageSamplerJob.perform_now

    assert_equal :rejected, serving.reload.credential_state,
      "an unreachable probe is not a verdict in either direction — it must not clear one either"
  end

  test "a later successful sample puts a refused account back in the pool" do
    serving = account("serving@example.com", current: true)
    serving.record_credential_probe!(
      QuotaCheckService::Result.new(success: false, unreachable: false, status_code: 401,
        error_message: "No rate-limit headers in response (HTTP 401)."),
      probed_token: serving.claude_access_token
    )
    assert_not ClaudeAccount.any_serviceable_for?(ClaudeAuthProvider::RUNTIME)
    stub_probe

    ClaudeUsageSamplerJob.perform_now

    assert_equal :verified, serving.reload.credential_state
    assert ClaudeAccount.any_serviceable_for?(ClaudeAuthProvider::RUNTIME)
  end

  test "a refused token gets one repair refresh, and only one, however many ticks see it" do
    serving = account("serving@example.com", current: true)
    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(success: false, unreachable: false, status_code: 401,
        error_message: "No rate-limit headers in response (HTTP 401).")
    )
    # A refresh that fails leaves the token — and so the verdict — where it was.
    # A refresh that succeeded would write a new token and retire the verdict,
    # which is a new token death and earns its own single repair.
    ClaudeAccount.any_instance.expects(:refresh_token!).once.returns(false)

    ClaudeUsageSamplerJob.perform_now
    assert_equal :rejected, serving.reload.credential_state

    ClaudeUsageSamplerJob.perform_now
    ClaudeUsageSamplerJob.perform_now
  end

  test "an answered failure that is not about authentication spends no refresh" do
    account("serving@example.com", current: true)
    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(success: false, unreachable: false, status_code: 400,
        error_message: "No rate-limit headers in response (HTTP 400).")
    )
    ClaudeAccount.any_instance.expects(:refresh_token!).never

    ClaudeUsageSamplerJob.perform_now
  end

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

  # Both budgets move together, the way the job derives them, so a test that
  # narrows the success budget does not silently leave a wide attempt budget.
  def with_spare_cap(cap, attempts: cap * 2)
    originals = { MAX_SPARE_PROBES_PER_TICK: cap, MAX_SPARE_ATTEMPTS_PER_TICK: attempts }
      .to_h { |name, value| [ name, [ ClaudeUsageSamplerJob.const_get(name), value ] ] }
    originals.each { |name, (_was, now)| reset_const(name, now) }
    yield
  ensure
    originals.each { |name, (was, _now)| reset_const(name, was) }
  end

  def reset_const(name, value)
    ClaudeUsageSamplerJob.send(:remove_const, name)
    ClaudeUsageSamplerJob.const_set(name, value)
  end
end
