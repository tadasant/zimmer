# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class AccountRotationServiceTest < ActiveSupport::TestCase
  setup do
    @service = AccountRotationService.new

    # There are no credential paths to redirect. Rotation is a DB operation:
    # every session is spawned with its own CLAUDE_CONFIG_DIR and the current
    # account's access token, so nothing here touches a file (issue #618).

    # Stub QuotaCheckService.check_with_token to avoid real API calls
    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(
        success: true,
        subscription_type: "claude_max",
        rate_limit_tier: "tier_4",
        utilization_5h: 0.5,
        utilization_7d: 0.3,
        status_5h: "allowed",
        status_7d: "allowed",
        reset_5h: 3.hours.from_now,
        reset_7d: 5.days.from_now
      )
    )

    # activate_next_account now always calls refresh_token! to validate tokens
    # against Anthropic's OAuth endpoint. Stub a generic success response so
    # tests that don't explicitly exercise refresh failure get a passing probe.
    successful_refresh = Net::HTTPSuccess.new("1.1", "200", "OK")
    successful_refresh.stubs(:code).returns("200")
    successful_refresh.stubs(:body).returns({
      access_token: "stubbed-access-token",
      refresh_token: "stubbed-refresh-token",
      expires_in: 3600
    }.to_json)
    Net::HTTP.any_instance.stubs(:request).returns(successful_refresh)
  end

  # A quota reading from a healthy account — what the setup stub returns.
  def healthy_probe
    QuotaCheckService::Result.new(
      success: true, subscription_type: "claude_max", rate_limit_tier: "tier_4",
      utilization_5h: 0.5, utilization_7d: 0.3, status_5h: "allowed", status_7d: "allowed",
      reset_5h: 3.hours.from_now, reset_7d: 5.days.from_now
    )
  end

  # Anthropic answering and refusing the token: a reachable API, no rate-limit
  # headers. This is the only shape that condemns a credential.
  def rejected_probe
    QuotaCheckService::Result.new(
      success: false, unreachable: false, status_code: 401,
      error_message: "No rate-limit headers in response (HTTP 401). Token may be expired or invalid."
    )
  end

  def reject_token(account)
    QuotaCheckService.stubs(:check_with_token).returns(healthy_probe)
    QuotaCheckService.stubs(:check_with_token)
      .with(account.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken"))
      .returns(rejected_probe)
  end

  # A successful OAuth refresh returning a named token pair.
  def refresh_response(access_token)
    response = Net::HTTPSuccess.new("1.1", "200", "OK")
    response.stubs(:code).returns("200")
    response.stubs(:body).returns({
      access_token: access_token, refresh_token: "#{access_token}-refresh", expires_in: 3600
    }.to_json)
    response
  end

  # Make every OAuth refresh fail with the given code. 503 is transient, so
  # refresh_token! returns false without marking the account needs_reauth.
  def fail_refresh_with(code)
    response = Net::HTTPServiceUnavailable.new("1.1", code.to_s, "Service Unavailable")
    response.stubs(:code).returns(code.to_s)
    response.stubs(:body).returns("Service Unavailable")
    Net::HTTP.any_instance.stubs(:request).returns(response)
  end

  # A reading whose 7-day window is spent: the API rejecting for the week, with
  # the reset still ahead.
  def capped_result(reset_7d: 2.days.from_now)
    QuotaCheckService::Result.new(
      success: true, utilization_5h: 0.29, utilization_7d: 1.0,
      status_5h: "allowed", status_7d: "rejected",
      reset_5h: 1.hour.from_now, reset_7d: reset_7d
    )
  end

  # Record that reading against an account WITHOUT letting the ingestion marking
  # fire, so the test exercises rotation's own pick-time check on evidence that
  # predates the marking (the real "snapshot taken before this shipped" case).
  def capped_snapshot(account, reset_7d: 2.days.from_now)
    account.quota_snapshots.create!(
      utilization_5h: 0.29, utilization_7d: 1.0,
      status_5h: "allowed", status_7d: "rejected",
      reset_5h: 1.hour.from_now, reset_7d: reset_7d, trigger: "page_view"
    )
  end

  test "rotate! marks current account as quota_exceeded and switches to next" do
    primary = claude_accounts(:primary)
    secondary = claude_accounts(:secondary)

    result = @service.rotate!

    assert result[:success]
    assert_equal secondary, result[:account]
    assert primary.reload.quota_exceeded?
    assert secondary.reload.is_current?
    assert_not primary.reload.is_current?
  end

  # The 2026-08-23 02:05Z outage in one assertion. A blanked credential logged
  # every session out; each session rotated away from the account it was holding;
  # every rotation stamped `quota_exceeded` on the account it left — and because
  # that label is what `ClaudeAccount.available` reads, a pool of healthy accounts
  # read as drained inside a minute and four sessions were parked against a noon
  # reset estimate.
  test "rotate! for a non-quota reason leaves the outgoing account active" do
    primary = claude_accounts(:primary)

    result = @service.rotate!(reason: "auth_recovery")

    assert result[:success]
    assert_equal "active", primary.reload.status,
      "Rotating away from an account is not evidence that its quota is spent"
    assert_not primary.reload.is_current?
  end

  # An unknown reason has to opt in, not be assumed in: over-labelling is the
  # failure this rule exists to prevent.
  test "rotate! for an unrecognised reason leaves the outgoing account active" do
    primary = claude_accounts(:primary)

    @service.rotate!(reason: "operator_switch")

    assert_equal "active", primary.reload.status
  end

  # The other direction: a non-quota rotation whose live probe condemns the
  # account still labels it, because that reading IS evidence.
  test "rotate! for a non-quota reason still labels an account its own reading condemns" do
    primary = claude_accounts(:primary)
    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(
        success: true, subscription_type: "claude_max", rate_limit_tier: "tier_4",
        utilization_5h: 1.0, utilization_7d: 1.0, status_5h: "rejected", status_7d: "rejected",
        reset_5h: 3.hours.from_now, reset_7d: 5.days.from_now
      )
    )

    @service.rotate!(reason: "auth_recovery")

    assert primary.reload.quota_exceeded?,
      "A reading that says both windows are spent condemns the account whatever the rotation was for"
  end

  # An account that cannot be probed at all is the blanked-credential case, and
  # the one that must not be guessed about.
  test "rotate! for a non-quota reason leaves an unprobeable account active" do
    primary = claude_accounts(:primary)
    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(success: false, error_message: "401 Unauthorized")
    )

    @service.rotate!(reason: "auth_recovery")

    assert_equal "active", primary.reload.status,
      "A pool we could not read is not evidence that its quota is gone"
  end

  # StructuredLogger#error ends in ErrorReporter.report_message, which answers a
  # Sentry::Event whenever a DSN is configured. #take_snapshot's rescue must not
  # let that object out: it is `present?`, answers no quota question, and
  # #mark_outgoing! would raise NoMethodError on it under the pool lock — on the
  # unprobeable-account path, which is the one that has to stay safe.
  test "rotate! survives a probe that raises, whatever the error reporter returns" do
    primary = claude_accounts(:primary)
    QuotaCheckService.stubs(:check_with_token).raises(StandardError.new("probe blew up"))
    StructuredLogger.any_instance.stubs(:error).returns(Object.new)

    result = @service.rotate!(reason: "auth_recovery")

    assert result[:success], "A failed probe must not abort the rotation"
    assert_equal "active", primary.reload.status
  end

  # `!windows_clear?` is the same predicate #effective_status renders and
  # QuotaResetCheckerJob restores on. `five_hour_window_spent?` is not: a counter
  # at the cap with no reset stamp satisfies it while `windows_clear?` is still
  # true, so rotation would write a label the rest of the app immediately
  # overrules — a mark nothing acts on, over an account every spawn path refuses.
  test "rotate! does not label an account whose reading windows_clear? still calls serviceable" do
    primary = claude_accounts(:primary)
    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(
        success: true, subscription_type: "claude_max", rate_limit_tier: "tier_4",
        utilization_5h: 1.0, utilization_7d: 0.2, status_5h: "allowed", status_7d: "allowed",
        reset_5h: nil, reset_7d: nil
      )
    )

    @service.rotate!(reason: "auth_recovery")

    assert_equal "active", primary.reload.status
  end

  test "rotate! creates an AccountRotationEvent" do
    primary = claude_accounts(:primary)
    secondary = claude_accounts(:secondary)

    assert_difference "AccountRotationEvent.count", 1 do
      @service.rotate!(reason: "quota_exceeded", triggered_by: "session:42")
    end

    event = AccountRotationEvent.last
    assert_equal primary, event.rotated_from
    assert_equal secondary, event.rotated_to
    assert_equal "quota_exceeded", event.reason
    assert_equal "automatic", event.source
    assert_equal "session:42", event.triggered_by
  end

  test "rotate! returns failure when no available accounts" do
    # Mark all accounts as quota_exceeded or unconfigured
    ClaudeAccount.active.where.not(oauth_config: {}).each { |a| a.update!(status: :quota_exceeded) }

    result = @service.rotate!

    assert_not result[:success]
    assert_equal "no_available_accounts", result[:reason]
  end

  test "rotate! takes snapshots of both outgoing and incoming accounts" do
    primary = claude_accounts(:primary)
    secondary = claude_accounts(:secondary)

    initial_primary_count = primary.quota_snapshots.count
    initial_secondary_count = secondary.quota_snapshots.count

    @service.rotate!

    assert_equal initial_primary_count + 1, primary.quota_snapshots.count
    assert_equal initial_secondary_count + 1, secondary.quota_snapshots.count
  end

  test "ensure_active_account! picks first available when no current set" do
    ClaudeAccount.update_all(is_current: false)

    result = @service.ensure_active_account!
    assert_not_nil result
    assert result.is_current?
    assert result.active?
  end

  test "parse_quota_reset_time parses simple time" do
    result = AccountRotationService.parse_quota_reset_time("You've hit your limit · resets 5pm (UTC)")
    assert_not_nil result
    assert_equal 17, result.hour # 5pm = 17:00
  end

  test "parse_quota_reset_time parses time with date" do
    result = AccountRotationService.parse_quota_reset_time("resets Mar 6, 3am (UTC)")
    assert_not_nil result
    assert_equal 3, result.hour
    assert_equal 3, result.month
  end

  test "parse_quota_reset_time returns nil for unparsable string" do
    result = AccountRotationService.parse_quota_reset_time("some random error")
    assert_nil result
  end

  test "parse_quota_reset_time returns nil for blank string" do
    assert_nil AccountRotationService.parse_quota_reset_time(nil)
    assert_nil AccountRotationService.parse_quota_reset_time("")
  end

  test "rotate! refreshes expired tokens for incoming account" do
    # Make secondary have expired tokens
    secondary = claude_accounts(:secondary)
    config = secondary.oauth_config.deep_dup
    config["credentials_json"]["claudeAiOauth"]["expiresAt"] = 1000000000000
    secondary.update!(oauth_config: config)

    successful_response = Net::HTTPSuccess.new("1.1", "200", "OK")
    successful_response.stubs(:code).returns("200")
    successful_response.stubs(:body).returns({
      access_token: "refreshed-secondary-token",
      refresh_token: "refreshed-secondary-refresh",
      expires_in: 3600
    }.to_json)

    Net::HTTP.any_instance.stubs(:request).returns(successful_response)

    result = @service.rotate!
    assert result[:success]
    assert_equal secondary, result[:account]

    secondary.reload
    assert_equal "refreshed-secondary-token", secondary.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
    assert secondary.is_current?
  end

  test "rotate! skips account with failed refresh and tries next without bricking it" do
    secondary = claude_accounts(:secondary)
    tertiary = claude_accounts(:tertiary)

    # 503 -> not a recognised auth rejection, so refresh_token! does
    # NOT mark needs_reauth — this tests the rotation service's behavior.
    failed_response = Net::HTTPServiceUnavailable.new("1.1", "503", "Service Unavailable")
    failed_response.stubs(:code).returns("503")
    failed_response.stubs(:body).returns("Service Unavailable")

    successful_response = Net::HTTPSuccess.new("1.1", "200", "OK")
    successful_response.stubs(:code).returns("200")
    successful_response.stubs(:body).returns({
      access_token: "tertiary-token",
      refresh_token: "tertiary-refresh",
      expires_in: 3600
    }.to_json)

    # Secondary refresh fails (503), then tertiary refresh succeeds
    Net::HTTP.any_instance.stubs(:request).returns(failed_response, successful_response)

    result = @service.rotate!
    assert result[:success]
    assert_equal tertiary, result[:account]

    # Secondary should NOT be marked needs_reauth by the rotation service.
    # The rotation service skips accounts with failed refresh but does not brick them.
    secondary.reload
    assert_not secondary.needs_reauth?, "Rotation should not mark accounts as needs_reauth on transient failure"
    assert secondary.active?, "Account should remain active after transient refresh failure during rotation"
    assert tertiary.reload.is_current?
  end

  test "rotate! allows refresh_token! to mark needs_reauth for permanent failures" do
    secondary = claude_accounts(:secondary)
    tertiary = claude_accounts(:tertiary)

    # 401 classifies as a dead credential -> refresh_token! marks needs_reauth
    failed_response = Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized")
    failed_response.stubs(:code).returns("401")
    failed_response.stubs(:body).returns({ error: "invalid_grant" }.to_json)

    successful_response = Net::HTTPSuccess.new("1.1", "200", "OK")
    successful_response.stubs(:code).returns("200")
    successful_response.stubs(:body).returns({
      access_token: "tertiary-token",
      refresh_token: "tertiary-refresh",
      expires_in: 3600
    }.to_json)

    # Secondary refresh fails (401, permanent), then tertiary refresh succeeds
    Net::HTTP.any_instance.stubs(:request).returns(failed_response, successful_response)

    result = @service.rotate!
    assert result[:success]
    assert_equal tertiary, result[:account]

    # needs_reauth was set by refresh_token! (permanent failure), not by the rotation service
    secondary.reload
    assert secondary.needs_reauth?
    assert tertiary.reload.is_current?
  end

  test "rotate! validates tokens via OAuth probe even when expiresAt looks fresh by date" do
    # Production bug repro: an account whose tokens look fresh by date
    # (expiresAt = 9999999999999, the fixture sentinel) but whose refresh
    # token is rejected by Anthropic. Before the fix, the date-only check let
    # these tokens through and every subsequent session 401'd. Expected
    # behavior: the probe fails and rotation skips the account.
    secondary = claude_accounts(:secondary) # expiresAt: 9999999999999, fake refresh token
    tertiary = claude_accounts(:tertiary)

    failed_response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    failed_response.stubs(:code).returns("400")
    failed_response.stubs(:body).returns({ error: "invalid_grant" }.to_json)

    successful_response = Net::HTTPSuccess.new("1.1", "200", "OK")
    successful_response.stubs(:code).returns("200")
    successful_response.stubs(:body).returns({
      access_token: "tertiary-fresh-token",
      refresh_token: "tertiary-fresh-refresh",
      expires_in: 3600
    }.to_json)

    # First refresh call (secondary, bogus tokens) → 400 invalid_grant
    # Second refresh call (tertiary, real tokens) → 200 success
    Net::HTTP.any_instance.stubs(:request).returns(failed_response, successful_response)

    result = @service.rotate!

    assert result[:success]
    assert_equal tertiary, result[:account]
    assert_not secondary.reload.is_current?, "Secondary must not become current — its probe failed"
    assert tertiary.reload.is_current?

    # The critical assertion: the account whose probe failed must not be the one
    # a session is about to be handed a token out of.
    assert_equal tertiary.claude_access_token,
      ClaudeAccount.current_account(ClaudeAuthProvider::RUNTIME).claude_access_token
  end

  test "rotate! returns no_available_accounts when every candidate fails token validation" do
    # All non-current accounts have unverifiable tokens. The rotation should
    # exhaust the pool and return failure rather than promote one of them.
    failed_response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    failed_response.stubs(:code).returns("400")
    failed_response.stubs(:body).returns({ error: "invalid_grant" }.to_json)

    Net::HTTP.any_instance.stubs(:request).returns(failed_response)

    primary = claude_accounts(:primary)

    result = @service.rotate!

    assert_not result[:success]
    assert_equal "no_available_accounts", result[:reason]
    assert_equal primary, ClaudeAccount.current_account(ClaudeAuthProvider::RUNTIME)
  end

  # Bootstrap tests — the pool, not the filesystem. There is no
  # adopt-whatever-is-on-disk path any more: an empty pool is answered by the
  # Authenticate button on /inference, not by trusting a file. See issue #618.

  test "ensure_active_account! returns nil when no DB account holds usable credentials" do
    ClaudeAccount.destroy_all
    ClaudeAccount.create!(email: "not-matching@example.com", priority: 0)

    assert_nil @service.ensure_active_account!
  end

  # ── #248: rotation must not hand out an account already known to be capped ──

  test "rotate! skips a candidate whose 7-day window is spent and marks it exceeded" do
    secondary = claude_accounts(:secondary)
    tertiary = claude_accounts(:tertiary)
    capped_snapshot(secondary)

    result = @service.rotate!

    assert result[:success]
    assert_equal tertiary, result[:account], "rotation must skip the account whose week is spent"
    assert secondary.reload.quota_exceeded?, "the skipped account must leave the available pool"
    assert_not secondary.is_current?
  end

  test "rotate! still picks a candidate whose spent window has since reset" do
    secondary = claude_accounts(:secondary)
    # Rejected on the 7-day window, but that window's reset time has passed — the
    # sliding window has cleared, so the reading no longer says anything.
    capped_snapshot(secondary, reset_7d: 1.minute.ago)

    result = @service.rotate!

    assert result[:success]
    assert_equal secondary, result[:account]
    assert secondary.reload.active?
  end

  test "rotate! reports no_available_accounts when every candidate is capped" do
    ClaudeAccount.available.for_runtime(ClaudeAuthProvider::RUNTIME).each do |account|
      capped_snapshot(account) unless account.is_current?
    end

    result = @service.rotate!

    assert_not result[:success]
    assert_equal "no_available_accounts", result[:reason]
  end

  test "a snapshot showing a spent week takes the account out of the pool as it lands" do
    secondary = claude_accounts(:secondary)

    QuotaSnapshotService.save_snapshot(secondary, capped_result, trigger: "page_view")

    assert secondary.reload.quota_exceeded?
    assert_not_includes ClaudeAccount.available.for_runtime(ClaudeAuthProvider::RUNTIME), secondary
  end

  # ── #239: bootstrap must validate before promoting ─────────────────

  test "ensure_active_account! skips an account whose token Anthropic rejects" do
    ClaudeAccount.update_all(is_current: false)
    primary = claude_accounts(:primary)
    secondary = claude_accounts(:secondary)

    reject_token(primary)
    # The refresh a refusal triggers fails too (503 is transient, so it does not
    # condemn the account) — the #239 case is a candidate that stays unusable.
    fail_refresh_with(503)

    result = @service.ensure_active_account!

    assert_equal secondary, result, "the first available account's token was rejected, so it must be skipped"
    assert secondary.reload.is_current?
    assert_not primary.reload.is_current?
  end

  test "ensure_active_account! does not keep a current account whose token Anthropic refused" do
    # The 2026-07-31 shape: one `active` account, credentials stored, and a 401 on
    # every request made with them. `has_valid_config?` said "credentials stored",
    # so the current-account branch returned it to every spawn for an hour without
    # anybody presenting it to Anthropic.
    primary = claude_accounts(:primary)
    secondary = claude_accounts(:secondary)
    primary.record_credential_probe!(rejected_probe, probed_token: primary.claude_access_token)
    reject_token(primary)
    fail_refresh_with(503)

    result = @service.ensure_active_account!

    assert_equal secondary, result, "a refused credential must not be handed to the next session"
    assert secondary.reload.is_current?
  end

  test "a recorded refusal is only a reason to re-check, not a condemnation" do
    # The recorded verdict takes the account out of the fast path; the probe on the
    # way through is what decides. An account whose token started working again —
    # a refresh landed, a human re-authenticated — comes straight back.
    primary = claude_accounts(:primary)
    primary.record_credential_probe!(rejected_probe, probed_token: primary.claude_access_token)

    assert_equal primary, @service.ensure_active_account!
    assert_equal :verified, primary.reload.credential_state
  end

  test "ensure_active_account! keeps a current account whose probe merely could not reach Anthropic" do
    primary = claude_accounts(:primary)
    primary.record_credential_probe!(
      QuotaCheckService::Result.new(success: false, unreachable: true, error_message: "timeout"),
      probed_token: primary.claude_access_token
    )

    assert_equal primary, @service.ensure_active_account!,
      "an Anthropic blip is not a verdict — depose the pool on one and the instance cannot spawn at all"
  end

  test "ensure_active_account! records what the bootstrap probe learned about each candidate" do
    ClaudeAccount.update_all(is_current: false)
    primary = claude_accounts(:primary)
    secondary = claude_accounts(:secondary)
    reject_token(primary)
    fail_refresh_with(503)

    assert_equal secondary, @service.ensure_active_account!

    assert_equal :rejected, primary.reload.credential_state,
      "the page has to be able to say WHY the pool skipped this account"
    assert_equal :verified, secondary.reload.credential_state
  end

  test "bootstrap promotes a candidate whose probe was answered with something other than a refusal" do
    # A 400 for a retired probe model, a 404, a header-stripping proxy: an
    # Anthropic-side or configuration fault, not a verdict on the credential.
    # Skipping on one skips every candidate at once and the instance cannot spawn.
    ClaudeAccount.update_all(is_current: false)
    primary = claude_accounts(:primary)
    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(success: false, unreachable: false, status_code: 400,
        error_message: "No rate-limit headers in response (HTTP 400).")
    )
    ClaudeAccount.any_instance.expects(:refresh_token!).never

    assert_equal primary, @service.ensure_active_account!
    assert_equal :unverified, primary.reload.credential_state
  end

  test "bootstrap skips a candidate that holds no access token at all" do
    ClaudeAccount.update_all(is_current: false)
    primary = claude_accounts(:primary)
    secondary = claude_accounts(:secondary)
    primary.update!(oauth_config: { "claude_json" => { "oauthAccount" => primary.email } })

    assert_equal secondary, @service.ensure_active_account!,
      "an identity with no token is nothing a session could be handed"
  end

  test "ensure_active_account! does not refresh a candidate whose token already works" do
    # The probe is non-consuming; a refresh spends a single-use token, and
    # spending one per candidate is what drained the pool in #242.
    ClaudeAccount.update_all(is_current: false)
    Net::HTTP.any_instance.expects(:request).never

    assert_equal claude_accounts(:primary), @service.ensure_active_account!
  end

  test "ensure_active_account! records the candidate's live reading" do
    # The probe already carries this account's quota state — throwing it away
    # would leave rotation with no evidence about an account never made current.
    ClaudeAccount.update_all(is_current: false)
    primary = claude_accounts(:primary)

    assert_difference -> { primary.quota_snapshots.count }, 1 do
      assert_equal primary, @service.ensure_active_account!
    end
    assert_equal "bootstrap", primary.latest_snapshot.trigger
  end

  test "ensure_active_account! skips a candidate whose live reading shows a spent week" do
    # No stored snapshot, so the stale-evidence check cannot see this — only the
    # live probe can.
    ClaudeAccount.update_all(is_current: false)
    primary = claude_accounts(:primary)
    secondary = claude_accounts(:secondary)
    QuotaCheckService.stubs(:check_with_token).returns(healthy_probe)
    QuotaCheckService.stubs(:check_with_token)
      .with(primary.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken"))
      .returns(capped_result)

    result = @service.ensure_active_account!

    assert_equal secondary, result
    assert primary.reload.quota_exceeded?, "the live reading must take the capped account out of the pool"
  end

  test "rotate! counts one quota hit per rotation even when the snapshot marks the account" do
    primary = claude_accounts(:primary)
    QuotaCheckService.stubs(:check_with_token).returns(healthy_probe)
    QuotaCheckService.stubs(:check_with_token)
      .with(primary.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken"))
      .returns(capped_result)
    hits_before = primary.quota_hit_count

    @service.rotate!

    assert_equal hits_before + 1, primary.reload.quota_hit_count
    assert primary.quota_exceeded?
  end

  test "rotate! rotates on when the incoming account's fresh reading condemns it" do
    secondary = claude_accounts(:secondary)
    tertiary = claude_accounts(:tertiary)
    # Rotation validates by refreshing, so the snapshot that follows reads the
    # POST-refresh token — give secondary's refresh a distinguishable one and cap
    # that. Every other account keeps the setup's generic refresh.
    Net::HTTP.any_instance.stubs(:request)
      .with { |req| req.body.to_s.include?("test_refresh_token_2") }
      .returns(refresh_response("secondary-rotated-token"))
    QuotaCheckService.stubs(:check_with_token).returns(healthy_probe)
    QuotaCheckService.stubs(:check_with_token).with("secondary-rotated-token").returns(capped_result)

    result = @service.rotate!

    assert result[:success]
    assert_equal tertiary, result[:account],
      "an account the activation snapshot just condemned must not be handed to the session"
    assert secondary.reload.quota_exceeded?
    assert tertiary.reload.is_current?
  end

  test "ensure_active_account! returns nil when every available account's token is rejected" do
    ClaudeAccount.update_all(is_current: false)
    QuotaCheckService.stubs(:check_with_token).returns(rejected_probe)

    assert_nil @service.ensure_active_account!
    assert_nil ClaudeAccount.current_account
  end

  test "ensure_active_account! still promotes when the probe cannot reach Anthropic" do
    # A network failure is evidence about the network, not about the credentials.
    # Reading it as a rejection would park every session on the instance at once.
    ClaudeAccount.update_all(is_current: false)
    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(
        success: false, unreachable: true,
        error_message: "Cannot reach Anthropic API: getaddrinfo"
      )
    )

    result = @service.ensure_active_account!

    assert_equal claude_accounts(:primary), result
    assert result.reload.is_current?
  end

  test "ensure_active_account! skips an account whose 7-day window is spent" do
    ClaudeAccount.update_all(is_current: false)
    primary = claude_accounts(:primary)
    secondary = claude_accounts(:secondary)
    capped_snapshot(primary)

    result = @service.ensure_active_account!

    assert_equal secondary, result
    assert primary.reload.quota_exceeded?
  end

  test "ensure_active_account! refreshes a refused candidate and re-probes it" do
    # A stale access token is the one refusal a refresh can fix, so a refusal —
    # and only a refusal — buys the candidate a refresh and a second probe.
    ClaudeAccount.destroy_all
    account = ClaudeAccount.create!(
      email: "stale@example.com", priority: 0,
      oauth_config: {
        "claude_json" => { "oauthAccount" => "stale@example.com" },
        "credentials_json" => { "claudeAiOauth" => {
          "accessToken" => "stale-access", "refreshToken" => "stale-refresh", "expiresAt" => 1000000000000
        } }
      }
    )

    QuotaCheckService.stubs(:check_with_token).with("stale-access").returns(rejected_probe)
    QuotaCheckService.stubs(:check_with_token).with("stubbed-access-token").returns(healthy_probe)

    assert_equal account, @service.ensure_active_account!
    assert account.reload.is_current?
  end
end
