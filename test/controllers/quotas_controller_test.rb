# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class QuotasControllerTest < ActionDispatch::IntegrationTest
  setup do
    # switch_account now always probes Anthropic's OAuth endpoint via
    # refresh_token! before allowing the switch. Stub a generic success
    # response so tests that don't explicitly exercise refresh failure get
    # a passing probe.
    successful_refresh = Net::HTTPSuccess.new("1.1", "200", "OK")
    successful_refresh.stubs(:code).returns("200")
    successful_refresh.stubs(:body).returns({
      access_token: "stubbed-access-token",
      refresh_token: "stubbed-refresh-token",
      expires_in: 3600
    }.to_json)
    Net::HTTP.any_instance.stubs(:request).returns(successful_refresh)

    # switch_account now routes through AccountRotationService#activate!,
    # which writes ~/.claude.json + ~/.claude/.credentials.json and takes a
    # quota snapshot. Redirect filesystem writes to a tmp dir and stub the
    # snapshot probe so tests don't touch real credentials or call the API.
    @switch_tmpdir = Dir.mktmpdir
    @original_claude_json = ClaudeAuthProvider::CLAUDE_JSON_PATH
    @original_credentials_json = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
    ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
    ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, File.join(@switch_tmpdir, "claude.json"))
    ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
    ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, File.join(@switch_tmpdir, ".credentials.json"))

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

    # Codex activate! writes ~/.codex/auth.json. Redirect it to a tmp dir so
    # codex switch/delete tests don't clobber the real worker auth file.
    @codex_tmpdir = Dir.mktmpdir
    @original_codex_auth_json = CodexAuthProvider::AUTH_JSON_PATH
    CodexAuthProvider.send(:remove_const, :AUTH_JSON_PATH)
    CodexAuthProvider.const_set(:AUTH_JSON_PATH, File.join(@codex_tmpdir, "auth.json"))
  end

  teardown do
    FileUtils.rm_rf(@switch_tmpdir) if @switch_tmpdir
    FileUtils.rm_rf(@codex_tmpdir) if @codex_tmpdir
    if @original_claude_json
      ClaudeAuthProvider.send(:remove_const, :CLAUDE_JSON_PATH)
      ClaudeAuthProvider.const_set(:CLAUDE_JSON_PATH, @original_claude_json)
    end
    if @original_credentials_json
      ClaudeAuthProvider.send(:remove_const, :CREDENTIALS_JSON_PATH)
      ClaudeAuthProvider.const_set(:CREDENTIALS_JSON_PATH, @original_credentials_json)
    end
    if @original_codex_auth_json
      CodexAuthProvider.send(:remove_const, :AUTH_JSON_PATH)
      CodexAuthProvider.const_set(:AUTH_JSON_PATH, @original_codex_auth_json)
    end
  end

  # ── show (renders immediately with cached data) ───────────────────

  test "show renders page with cached snapshots" do
    get quotas_url

    assert_response :success
    assert_select "h1", "Quotas"
    assert_select "#aggregate_stats"
    assert_select "h2", "Accounts"
  end

  test "show has back link to sessions index" do
    get quotas_url

    assert_select "a[href=?]", root_path
  end

  test "show has Refresh All button" do
    get quotas_url

    assert_response :success
    assert_select "form[action=?]", refresh_all_quotas_path
  end

  test "show renders account cards with per-account refresh buttons" do
    get quotas_url

    assert_response :success
    # The quotas page is scoped to the Claude Code pool; Codex accounts (a
    # different runtime in the shared table) are not rendered here.
    cards = ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME).order(:priority)
    assert cards.exists?
    cards.each do |account|
      assert_select "#account_card_#{account.id}"
      assert_select "form[action=?]", refresh_account_quotas_path(account)
    end
    # Codex accounts must NOT appear on the Claude quotas page.
    ClaudeAccount.for_runtime(CodexAuthProvider::RUNTIME).each do |account|
      assert_select "#account_card_#{account.id}", count: 0
    end
  end

  test "show does not make API calls" do
    QuotaCheckService.expects(:check_with_token).never

    get quotas_url

    assert_response :success
  end

  test "show auto-adopts filesystem identity when CLI was manually switched" do
    primary = claude_accounts(:primary)
    secondary = claude_accounts(:secondary)

    # primary is DB-current; CLI was manually switched to secondary on disk.
    # Faithful manual `claude /login`: the shared owner marker still names primary
    # (older mtime), while the CLI wrote secondary's identity + credentials "now".
    primary.update!(last_rotated_to_at: 1.hour.ago)
    ClaudeAccount.write_credentials_owner_marker!(primary.email)
    past = 2.hours.ago.to_time
    File.utime(past, past, ClaudeAuthProvider.credentials_owner_path)
    File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH,
      JSON.pretty_generate(secondary.oauth_config["claude_json"]))
    File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH,
      JSON.pretty_generate(secondary.oauth_config["credentials_json"]))

    get quotas_url

    assert_response :success
    assert secondary.reload.is_current?, "show should auto-adopt filesystem identity"
    assert_not primary.reload.is_current?
  end

  test "should route GET /quotas to quotas#show" do
    assert_routing(
      { method: :get, path: "/quotas" },
      { controller: "quotas", action: "show" }
    )
  end

  # ── refresh_all ────────────────────────────────────────────────────

  test "refresh_all probes each account and streams updates" do
    result = QuotaCheckService::Result.new(
      success: true,
      subscription_type: "max",
      rate_limit_tier: "default_claude_max_20x",
      email: "test@example.com",
      utilization_5h: 0.42,
      utilization_7d: 0.15,
      status_5h: "allowed",
      status_7d: "allowed",
      reset_5h: 2.hours.from_now,
      reset_7d: 3.days.from_now
    )
    QuotaCheckService.stubs(:check_with_token).returns(result)

    post refresh_all_quotas_url, headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_includes response.content_type, "text/vnd.turbo-stream.html"
  end

  test "refresh_all auto-heals quota_exceeded account with low utilization" do
    exceeded = claude_accounts(:exceeded)
    assert exceeded.quota_exceeded?

    exceeded.quota_snapshots.destroy_all
    exceeded.quota_snapshots.create!(
      utilization_5h: 0.0,
      utilization_7d: 0.72,
      status_5h: "allowed",
      status_7d: "allowed",
      reset_5h: 3.hours.from_now,
      reset_7d: 5.days.from_now,
      trigger: "rotation"
    )

    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(success: false, error_message: "test")
    )

    post refresh_all_quotas_url, headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert exceeded.reload.active?, "Account should be auto-healed to active"
  end

  test "should route POST /quotas/refresh_all" do
    assert_routing(
      { method: :post, path: "/quotas/refresh_all" },
      { controller: "quotas", action: "refresh_all" }
    )
  end

  # ── refresh_account ────────────────────────────────────────────────

  test "refresh_account probes single account and returns turbo stream" do
    account = claude_accounts(:primary)
    result = QuotaCheckService::Result.new(
      success: true,
      subscription_type: "max",
      rate_limit_tier: "default_claude_max_20x",
      email: account.email,
      utilization_5h: 0.55,
      utilization_7d: 0.30,
      status_5h: "allowed",
      status_7d: "allowed",
      reset_5h: 2.hours.from_now,
      reset_7d: 3.days.from_now
    )
    QuotaCheckService.stubs(:check_with_token).returns(result)

    post refresh_account_quotas_url(account), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_includes response.content_type, "text/vnd.turbo-stream.html"
  end

  test "should route POST /quotas/refresh_account/:id" do
    assert_routing(
      { method: :post, path: "/quotas/refresh_account/1" },
      { controller: "quotas", action: "refresh_account", id: "1" }
    )
  end

  # ── switch_account ─────────────────────────────────────────────────

  test "switch_account switches to account with valid config" do
    secondary = claude_accounts(:secondary)

    post switch_account_path(secondary)

    assert_redirected_to quotas_path(runtime: "claude_code")
    assert secondary.reload.is_current?
    assert_not claude_accounts(:primary).reload.is_current?
    assert_equal "Switched to sam@tadasant.com", flash[:notice]
  end

  test "switch_account creates a manual rotation event" do
    secondary = claude_accounts(:secondary)

    assert_difference "AccountRotationEvent.count", 1 do
      post switch_account_path(secondary)
    end

    event = AccountRotationEvent.last
    assert_equal claude_accounts(:primary), event.rotated_from
    assert_equal secondary, event.rotated_to
    assert_equal "manual_switch", event.reason
    assert_equal "manual", event.source
  end

  test "switch_account writes the new account's config to the filesystem" do
    # The bug: previously, manual switch only updated the DB and skipped the
    # filesystem write that auto-rotation performs. Subsequent session spawns
    # would still use the previous account's credentials until reconciliation
    # eventually caught up. The fix routes both paths through
    # AccountRotationService#activate!.
    secondary = claude_accounts(:secondary)

    post switch_account_path(secondary)

    assert_redirected_to quotas_path(runtime: "claude_code")
    assert File.exist?(ClaudeAuthProvider::CLAUDE_JSON_PATH),
      "switch_account must write ~/.claude.json"
    assert File.exist?(ClaudeAuthProvider::CREDENTIALS_JSON_PATH),
      "switch_account must write ~/.claude/.credentials.json"

    claude_json = JSON.parse(File.read(ClaudeAuthProvider::CLAUDE_JSON_PATH))
    assert_equal secondary.email, claude_json["oauthAccount"],
      "~/.claude.json must reflect the newly-current account's identity"
  end

  test "switch_account takes a quota snapshot for the newly-current account" do
    secondary = claude_accounts(:secondary)

    initial_count = secondary.quota_snapshots.count
    post switch_account_path(secondary)

    assert_redirected_to quotas_path(runtime: "claude_code")
    assert_equal initial_count + 1, secondary.quota_snapshots.count,
      "switch_account must take a snapshot for the newly-current account"
    assert_equal "manual_switch", secondary.quota_snapshots.order(created_at: :desc).first.trigger
  end

  test "switch_account rejects account without oauth tokens" do
    unconfigured = claude_accounts(:unconfigured)

    post switch_account_path(unconfigured)

    assert_redirected_to quotas_path(runtime: "claude_code")
    assert_match "no credentials stored", flash[:alert]
    assert claude_accounts(:primary).reload.is_current?
    assert_not unconfigured.reload.is_current?
  end

  test "should route POST /quotas/switch_account/:id" do
    assert_routing(
      { method: :post, path: "/quotas/switch_account/1" },
      { controller: "quotas", action: "switch_account", id: "1" }
    )
  end

  test "switch_account refreshes expired tokens before switching" do
    secondary = claude_accounts(:secondary)
    config = secondary.oauth_config.deep_dup
    config["credentials_json"]["claudeAiOauth"]["expiresAt"] = 1000000000000
    secondary.update!(oauth_config: config)

    successful_response = Net::HTTPSuccess.new("1.1", "200", "OK")
    successful_response.stubs(:code).returns("200")
    successful_response.stubs(:body).returns({
      access_token: "refreshed-token",
      refresh_token: "refreshed-refresh",
      expires_in: 3600
    }.to_json)

    Net::HTTP.any_instance.stubs(:request).returns(successful_response)

    post switch_account_path(secondary)

    assert_redirected_to quotas_path(runtime: "claude_code")
    assert_equal "Switched to sam@tadasant.com", flash[:notice]
    secondary.reload
    assert secondary.is_current?
    assert_equal "refreshed-token", secondary.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
  end

  test "switch_account rejects account when token refresh fails" do
    secondary = claude_accounts(:secondary)

    failed_response = Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized")
    failed_response.stubs(:code).returns("401")
    failed_response.stubs(:body).returns({ error: "invalid_grant" }.to_json)

    Net::HTTP.any_instance.stubs(:request).returns(failed_response)

    post switch_account_path(secondary)

    assert_redirected_to quotas_path(runtime: "claude_code")
    assert_match "token validation failed", flash[:alert]
    assert claude_accounts(:primary).reload.is_current?
  end

  test "switch_account validates tokens via OAuth probe even when expiresAt looks fresh by date" do
    # Bug fix: secondary has fixture sentinel expiresAt: 9999999999999 (year 2286)
    # but a refresh_token that Anthropic rejects. Without the probe, the date
    # check would skip validation and switch to a bogus account, eventually
    # writing garbage to ~/.claude/.credentials.json on next session.
    secondary = claude_accounts(:secondary)

    failed_response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
    failed_response.stubs(:code).returns("400")
    failed_response.stubs(:body).returns({ error: "invalid_grant" }.to_json)

    Net::HTTP.any_instance.stubs(:request).returns(failed_response)

    post switch_account_path(secondary)

    assert_redirected_to quotas_path(runtime: "claude_code")
    assert_match "token validation failed", flash[:alert]
    assert_not secondary.reload.is_current?, "Switch must not succeed when probe rejects the tokens"
    assert claude_accounts(:primary).reload.is_current?
  end

  test "switch_account rejects account without refresh token" do
    secondary = claude_accounts(:secondary)
    config = secondary.oauth_config.deep_dup
    config["credentials_json"]["claudeAiOauth"].delete("refreshToken")
    secondary.update!(oauth_config: config)

    post switch_account_path(secondary)

    assert_redirected_to quotas_path(runtime: "claude_code")
    assert_match "no refresh token", flash[:alert]
    assert claude_accounts(:primary).reload.is_current?
  end

  # ── sync_from_filesystem ───────────────────────────────────────────

  test "sync_from_filesystem redirects with notice when tokens are captured" do
    ClaudeAccount.stubs(:filesystem_oauth_email).returns("sam@tadasant.com")
    ClaudeAccount.stubs(:sync_from_filesystem!).returns(claude_accounts(:secondary))

    post sync_from_filesystem_quotas_path

    assert_redirected_to quotas_path
    assert_match "Captured tokens for sam@tadasant.com", flash[:notice]
  end

  test "sync_from_filesystem redirects with alert when filesystem has no tokens" do
    ClaudeAccount.stubs(:filesystem_oauth_email).returns(nil)

    post sync_from_filesystem_quotas_path

    assert_redirected_to quotas_path
    assert_match "No OAuth tokens detected", flash[:alert]
  end

  test "sync_from_filesystem redirects with alert when no DB account matches filesystem email" do
    ClaudeAccount.stubs(:filesystem_oauth_email).returns("unknown@example.com")
    ClaudeAccount.stubs(:sync_from_filesystem!).returns(nil)

    post sync_from_filesystem_quotas_path

    assert_redirected_to quotas_path
    assert_match "no matching ClaudeAccount exists", flash[:alert]
    assert_match "unknown@example.com", flash[:alert]
  end

  test "should route POST /quotas/sync_from_filesystem" do
    assert_routing(
      { method: :post, path: "/quotas/sync_from_filesystem" },
      { controller: "quotas", action: "sync_from_filesystem" }
    )
  end

  # ── runtime sub-tabs ───────────────────────────────────────────────

  test "show renders a sub-tab link for each runtime" do
    get quotas_url

    assert_response :success
    assert_select "a[href=?]", quotas_path(runtime: "claude_code"), text: "Claude Code"
    assert_select "a[href=?]", quotas_path(runtime: "codex"), text: "Codex"
  end

  test "show defaults to the Claude Code runtime" do
    get quotas_url

    assert_response :success
    ClaudeAccount.for_runtime("claude_code").each do |account|
      assert_select "#account_card_#{account.id}"
    end
    ClaudeAccount.for_runtime("codex").each do |account|
      assert_select "#account_card_#{account.id}", count: 0
    end
  end

  test "show with runtime=codex renders only codex accounts" do
    get quotas_url(runtime: "codex")

    assert_response :success
    ClaudeAccount.for_runtime("codex").each do |account|
      assert_select "#account_card_#{account.id}"
    end
    ClaudeAccount.for_runtime("claude_code").each do |account|
      assert_select "#account_card_#{account.id}", count: 0
    end
  end

  test "show with an unknown runtime falls back to Claude Code" do
    get quotas_url(runtime: "bogus")

    assert_response :success
    assert_select "#account_card_#{claude_accounts(:primary).id}"
  end

  test "show codex tab does not render the Claude-only Refresh All button" do
    get quotas_url(runtime: "codex")

    assert_response :success
    assert_select "form[action=?]", refresh_all_quotas_path, count: 0
  end

  test "show codex card body shows auth note, not the Claude refresh-button prompt" do
    get quotas_url(runtime: "codex")

    assert_response :success
    # Codex accounts have no quota probe and no per-card refresh button, so the
    # Claude-only "Click the refresh button to fetch live data" prompt must not
    # appear — it would point at an affordance that does not exist on this tab.
    assert_select "body" do
      assert_select "*", text: /Click the refresh button/, count: 0
    end
    # API-key codex accounts explain the static auth; OAuth codex accounts note
    # OAuth. The fixture pool has both, so both notes should render.
    assert_match "no usage quota tracked", response.body
    assert_match "stored OpenAI API key", response.body
  end

  # ── add_account ────────────────────────────────────────────────────

  test "add_account creates an empty Claude OAuth account row" do
    assert_difference "ClaudeAccount.count", 1 do
      post add_account_quotas_path, params: { runtime: "claude_code", email: "new-claude@example.com", priority: 7 }
    end

    account = ClaudeAccount.find_by(email: "new-claude@example.com")
    assert_equal "claude_code", account.runtime
    assert_equal 7, account.priority
    assert_not account.has_valid_config?, "OAuth account is created without credentials"
    assert_equal "needs_reauth", account.status,
      "a credential-less account must not be seeded as :active — it isn't servable and shouldn't wear an Active badge"
    assert_redirected_to quotas_path(runtime: "claude_code")
    assert_match "Authenticate it", flash[:notice]
  end

  test "add_account with a codex api key creates a usable account" do
    assert_difference "ClaudeAccount.count", 1 do
      post add_account_quotas_path, params: { runtime: "codex", email: "new-codex@example.com", api_key: "sk-codex-123" }
    end

    account = ClaudeAccount.find_by(email: "new-codex@example.com")
    assert_equal "codex", account.runtime
    assert_equal "sk-codex-123", account.oauth_config["api_key"]
    assert account.has_valid_config?, "API-key account is usable immediately"
    assert_equal "active", account.status, "a config-carrying account stays :active on create"
    assert_redirected_to quotas_path(runtime: "codex")
  end

  test "add_account rejects a blank email" do
    assert_no_difference "ClaudeAccount.count" do
      post add_account_quotas_path, params: { runtime: "claude_code", email: "  " }
    end

    assert_redirected_to quotas_path(runtime: "claude_code")
    assert_match "Email is required", flash[:alert]
  end

  test "add_account rejects a duplicate email in the same runtime" do
    assert_no_difference "ClaudeAccount.count" do
      post add_account_quotas_path, params: { runtime: "claude_code", email: claude_accounts(:primary).email }
    end

    assert_match "already exists", flash[:alert]
  end

  test "add_account allows the same email on a different runtime" do
    # claude_accounts(:primary) is a claude_code account; adding a codex account
    # for the same email must succeed because email uniqueness is per-runtime.
    email = claude_accounts(:primary).email

    assert_difference "ClaudeAccount.count", 1 do
      post add_account_quotas_path, params: { runtime: "codex", email: email, api_key: "sk-codex-coexist" }
    end

    codex_account = ClaudeAccount.for_runtime("codex").find_by(email: email)
    assert codex_account, "expected a codex account to be created for #{email}"
    assert_equal "sk-codex-coexist", codex_account.oauth_config["api_key"]
    assert_redirected_to quotas_path(runtime: "codex")
  end

  # ── destroy_account ────────────────────────────────────────────────

  test "destroy_account deletes a non-current account" do
    secondary = claude_accounts(:secondary)

    assert_difference "ClaudeAccount.count", -1 do
      delete destroy_account_quotas_path(secondary)
    end

    assert_nil ClaudeAccount.find_by(id: secondary.id)
    assert_redirected_to quotas_path(runtime: "claude_code")
    assert_match "Deleted #{secondary.email}", flash[:notice]
  end

  test "destroy_account deleting the current account activates the next available one" do
    primary = claude_accounts(:primary)
    assert primary.is_current?

    assert_difference "AccountRotationEvent.count", 1 do
      delete destroy_account_quotas_path(primary)
    end

    assert_nil ClaudeAccount.find_by(id: primary.id)
    new_current = ClaudeAccount.current_account("claude_code")
    assert_not_nil new_current, "a replacement account should be activated"
    assert_not_equal primary.id, new_current.id

    event = AccountRotationEvent.last
    assert_nil event.rotated_from
    assert_equal new_current, event.rotated_to
    assert_equal "deleted_current_account", event.reason
    assert_match "Activated #{new_current.email}", flash[:notice]
  end

  test "destroy_account deleting the only account leaves the runtime with no current" do
    ClaudeAccount.for_runtime("codex").where.not(id: claude_accounts(:codex_primary).id).delete_all
    codex_primary = claude_accounts(:codex_primary)
    assert codex_primary.is_current?

    delete destroy_account_quotas_path(codex_primary)

    assert_nil ClaudeAccount.current_account("codex")
    assert_redirected_to quotas_path(runtime: "codex")
    assert_match "no active account", flash[:notice]
  end

  test "should route DELETE /quotas/account/:id" do
    assert_routing(
      { method: :delete, path: "/quotas/account/1" },
      { controller: "quotas", action: "destroy_account", id: "1" }
    )
  end

  test "should route POST /quotas/add_account" do
    assert_routing(
      { method: :post, path: "/quotas/add_account" },
      { controller: "quotas", action: "add_account" }
    )
  end

  # ── switch_account (codex) ─────────────────────────────────────────

  test "switch_account switches to a codex api-key account without a refresh probe" do
    api_key_account = claude_accounts(:codex_api_key)

    assert_difference "AccountRotationEvent.count", 1 do
      post switch_account_path(api_key_account)
    end

    assert api_key_account.reload.is_current?
    assert_not claude_accounts(:codex_primary).reload.is_current?
    assert_redirected_to quotas_path(runtime: "codex")

    event = AccountRotationEvent.last
    assert_equal api_key_account, event.rotated_to
    assert_equal "manual_switch", event.reason
  end

  test "switch_account switches to a codex OAuth account after a successful refresh probe" do
    # codex_secondary holds OAuth tokens (not an api-key account), so it must
    # pass the refresh probe before activation — the dual-runtime equivalent of
    # the Claude OAuth switch path. Stub the probe so no real token endpoint is hit.
    ClaudeAccount.any_instance.stubs(:refresh_token!).returns(true)
    oauth_account = claude_accounts(:codex_secondary)

    assert_difference "AccountRotationEvent.count", 1 do
      post switch_account_path(oauth_account)
    end

    assert oauth_account.reload.is_current?
    assert_not claude_accounts(:codex_primary).reload.is_current?
    assert_redirected_to quotas_path(runtime: "codex")
    assert File.exist?(CodexAuthProvider::AUTH_JSON_PATH),
      "codex switch must write ~/.codex/auth.json"

    event = AccountRotationEvent.last
    assert_equal oauth_account, event.rotated_to
    assert_equal "manual_switch", event.reason
  end

  test "switch_account rejects a codex OAuth account when the refresh probe fails" do
    ClaudeAccount.any_instance.stubs(:refresh_token!).returns(false)
    oauth_account = claude_accounts(:codex_secondary)

    post switch_account_path(oauth_account)

    assert_redirected_to quotas_path(runtime: "codex")
    assert_match "token validation failed", flash[:alert]
    assert_not oauth_account.reload.is_current?
    assert claude_accounts(:codex_primary).reload.is_current?
  end

  test "destroy_account deleting the current codex account activates a codex OAuth fallback" do
    # Remove the api-key account so the only remaining candidate is OAuth, forcing
    # the safe-delete fallback through the refresh-probe branch of
    # next_activatable_account. Stub the probe so no real token endpoint is hit.
    ClaudeAccount.any_instance.stubs(:refresh_token!).returns(true)
    claude_accounts(:codex_api_key).destroy!
    codex_primary = claude_accounts(:codex_primary)
    assert codex_primary.is_current?

    assert_difference "AccountRotationEvent.count", 1 do
      delete destroy_account_quotas_path(codex_primary)
    end

    new_current = ClaudeAccount.current_account("codex")
    assert_equal claude_accounts(:codex_secondary), new_current
    assert_redirected_to quotas_path(runtime: "codex")

    event = AccountRotationEvent.last
    assert_equal "deleted_current_account", event.reason
    assert_equal new_current, event.rotated_to
  end

  # ── rotation log (runtime isolation) ───────────────────────────────

  test "rotation log shows a runtime's own events even when the other runtime's are more recent" do
    # Regression guard: the runtime filter must be applied in SQL before the
    # LIMIT, otherwise a flood of recent Claude events could crowd Codex events
    # off the page and the Codex tab's rotation log would render empty.
    AccountRotationEvent.create!(rotated_to: claude_accounts(:codex_secondary), reason: "older_codex_event", source: "manual", created_at: 2.hours.ago)
    60.times do |i|
      AccountRotationEvent.create!(rotated_to: claude_accounts(:secondary), reason: "claude_event_#{i}", source: "manual", created_at: (i + 1).minutes.ago)
    end

    get quotas_url(runtime: "codex")

    assert_response :success
    assert_select "td", text: "older_codex_event"
    assert_select "td", text: "claude_event_0", count: 0
  end

  # ── add_account (runtime guard) ────────────────────────────────────

  test "add_account ignores an api_key passed for the Claude Code runtime" do
    post add_account_quotas_path, params: { runtime: "claude_code", email: "claude-no-key@example.com", api_key: "sk-should-be-ignored" }

    account = ClaudeAccount.find_by(email: "claude-no-key@example.com")
    assert_equal "claude_code", account.runtime
    assert_equal({}, account.oauth_config, "api_key must not be stored for Claude Code accounts")
    assert_not account.has_valid_config?
  end

  # ── start_login / login_status / submit_login_code / cancel_login ──

  test "start_login creates an attempt, enqueues the job, and renders the panel" do
    account = claude_accounts(:unconfigured)
    RuntimeLoginJob.expects(:perform_later).once

    assert_difference -> { account.runtime_login_attempts.count }, 1 do
      post start_login_quotas_path(account), headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :success
    assert_includes response.content_type, "text/vnd.turbo-stream.html"
    assert_select "turbo-stream[target=?]", "login_panel_#{account.id}"

    attempt = account.runtime_login_attempts.order(:created_at).last
    assert_equal "starting", attempt.status
    assert_equal account.runtime, attempt.runtime
  end

  test "start_login supersedes any in-flight attempt for the account" do
    account = claude_accounts(:unconfigured)
    stale = account.runtime_login_attempts.create!(runtime: account.runtime, status: "awaiting_user")
    RuntimeLoginJob.expects(:perform_later).once

    post start_login_quotas_path(account), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "canceled", stale.reload.status, "the prior live attempt must be superseded"
    assert_equal 1, account.runtime_login_attempts.active.count
  end

  test "start_login rejects a codex api-key account" do
    account = claude_accounts(:codex_api_key)
    RuntimeLoginJob.expects(:perform_later).never

    assert_no_difference -> { account.runtime_login_attempts.count } do
      post start_login_quotas_path(account), headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :success
    assert_match "don't use the login flow", flash[:alert]
  end

  test "login_status renders the login panel while the attempt is in flight" do
    account = claude_accounts(:unconfigured)
    attempt = account.runtime_login_attempts.create!(runtime: account.runtime, status: "awaiting_user")

    get login_status_quotas_path(attempt), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_select "turbo-stream[target=?]", "login_panel_#{account.id}"
  end

  test "login_status replaces the whole account card once the attempt succeeds" do
    account = claude_accounts(:unconfigured)
    attempt = account.runtime_login_attempts.create!(runtime: account.runtime, status: "succeeded")

    get login_status_quotas_path(attempt), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_select "turbo-stream[target=?]", "account_card_#{account.id}"
  end

  test "login_status lazily expires an attempt past its window" do
    account = claude_accounts(:unconfigured)
    attempt = account.runtime_login_attempts.create!(runtime: account.runtime, status: "awaiting_user")
    attempt.update_column(:expires_at, 1.minute.ago)

    get login_status_quotas_path(attempt), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "expired", attempt.reload.status
  end

  test "login_status keeps the verification URL visible while awaiting the pasted code" do
    # Regression: the awaiting_code state used to render only the paste-code form,
    # leaving the user asked for a code with no way to obtain it. The Claude
    # --claudeai flow prints the URL and blocks on its paste prompt nearly at
    # once, so the awaiting_user state that first surfaced the URL is usually
    # skipped between 2s polls — the URL must stay visible in awaiting_code.
    account = claude_accounts(:unconfigured)
    url = "https://claude.com/cai/oauth/authorize?code=abc123"
    attempt = account.runtime_login_attempts.create!(
      runtime: account.runtime,
      status: "awaiting_code",
      verification_url: url
    )

    get login_status_quotas_path(attempt), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_includes response.body, url, "awaiting_code must render the OAuth authorization URL"
    assert_includes response.body, submit_login_code_quotas_path(attempt),
      "the paste-code form must still render alongside the URL"
  end

  test "submit_login_code stores the pasted code on a live attempt" do
    account = claude_accounts(:unconfigured)
    attempt = account.runtime_login_attempts.create!(runtime: account.runtime, status: "awaiting_code")

    post submit_login_code_quotas_path(attempt),
      params: { code: "  auth-code-123  " },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "auth-code-123", attempt.reload.pasted_code
  end

  test "submit_login_code ignores a blank code" do
    account = claude_accounts(:unconfigured)
    attempt = account.runtime_login_attempts.create!(runtime: account.runtime, status: "awaiting_code")

    post submit_login_code_quotas_path(attempt),
      params: { code: "   " },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_nil attempt.reload.pasted_code
  end

  test "cancel_login marks a live attempt canceled" do
    account = claude_accounts(:unconfigured)
    attempt = account.runtime_login_attempts.create!(runtime: account.runtime, status: "awaiting_user")

    post cancel_login_quotas_path(attempt), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "canceled", attempt.reload.status
  end

  test "cancel_login leaves an already-terminal attempt untouched" do
    account = claude_accounts(:unconfigured)
    attempt = account.runtime_login_attempts.create!(runtime: account.runtime, status: "succeeded")

    post cancel_login_quotas_path(attempt), headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "succeeded", attempt.reload.status
  end

  test "should route POST /quotas/accounts/:id/login" do
    assert_routing(
      { method: :post, path: "/quotas/accounts/1/login" },
      { controller: "quotas", action: "start_login", id: "1" }
    )
  end

  test "should route GET /quotas/login/:attempt_id" do
    assert_routing(
      { method: :get, path: "/quotas/login/5" },
      { controller: "quotas", action: "login_status", attempt_id: "5" }
    )
  end
end
