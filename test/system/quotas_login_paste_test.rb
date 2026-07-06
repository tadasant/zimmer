require "application_system_test_case"

# Regression coverage for the Quotas "Authenticate" paste flow.
#
# The awaiting_code login panel carries a Stimulus poller
# (quotas_login_poller_controller.js) that refetches login_status every 2s. The
# panel contains the authorization-code <form> the user pastes into and clicks
# Submit on. The bug: the poller re-rendered (turbo_stream.replace) the whole
# panel on every tick, tearing out and rebuilding that form. A Submit click that
# landed after a tick hit a detached button (no request fired) or a freshly
# rebuilt-but-empty field (an empty code the controller drops) — so "pasting the
# code did nothing" and the login never completed.
#
# The fix gates the re-render on an actual status change: while the attempt
# stays awaiting_code the poller skips the redundant replace, leaving the form
# (node, value, focus) untouched so Submit always carries the real code through.
#
# This test exercises the path end to end: paste a code, let the live poller run
# through several ticks, click Submit, and assert the code reaches the backend
# (the attempt's pasted_code column — the exact value the worker hands to the
# held-open CLI). It fails on the pre-fix poller (the form is torn out from under
# the paste/click) and passes once redundant re-renders are skipped.
class QuotasLoginPasteTest < ApplicationSystemTestCase
  setup do
    # QuotasController#show reconciles the worker's ~/.claude credential files on
    # render. Point those paths at an empty tmp dir so the page render performs no
    # real filesystem work and reconcile is a clean no-op during the test.
    @login_tmpdir = Dir.mktmpdir
    @orig_claude_json = ClaudeAuthProvider::CLAUDE_JSON_PATH
    @orig_credentials_json = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
    stub_claude_path(:CLAUDE_JSON_PATH, File.join(@login_tmpdir, "claude.json"))
    stub_claude_path(:CREDENTIALS_JSON_PATH, File.join(@login_tmpdir, ".credentials.json"))
  end

  teardown do
    stub_claude_path(:CLAUDE_JSON_PATH, @orig_claude_json)
    stub_claude_path(:CREDENTIALS_JSON_PATH, @orig_credentials_json)
    FileUtils.remove_entry(@login_tmpdir) if @login_tmpdir && File.directory?(@login_tmpdir)
  end

  test "pasted authorization code reaches the backend when Submit is clicked across live poller ticks" do
    account = claude_accounts(:unconfigured)
    attempt = account.runtime_login_attempts.create!(
      runtime: "claude_code",
      status: "awaiting_code",
      verification_url: "https://claude.com/cai/oauth/authorize?test=1",
      expires_at: 14.minutes.from_now
    )

    visit quotas_url

    panel = "#login_attempt_#{attempt.id}"
    assert_selector "#{panel} input[name='code']", wait: 5

    # Count the poller's login_status fetches so we can prove it is actively
    # ticking (not dead) while we hold a pasted code in the field — the failure
    # this guards against only manifests when ticks land between paste and Submit.
    instrument_poll_counter(login_status_quotas_path(attempt.id))

    code = "test-auth-code-abc123#state-xyz"
    # Set the value in a single synchronous JS call rather than Capybara's
    # fill_in: a one-shot assignment mirrors a paste (which is what the user
    # does) and can't be interleaved by a tick. The retrying matcher confirms it
    # stuck.
    set_code_field(panel, code)
    assert_field "code", with: code, wait: 5

    # Let the live poller tick at least twice (interval is 2s). On the pre-fix
    # poller each tick tore the form out; here the form must survive untouched.
    wait_for_poll_count(2)

    # Same node, same value after the ticks — the form the user is about to
    # Submit was never rebuilt out from under them.
    assert_field "code", with: code, wait: 5

    click_button "Submit"

    # The end-to-end proof: the code the user pasted is what the backend
    # received (and would hand to the held-open CLI), delivered through a Submit
    # that fired across the live poller's ticks.
    assert_pasted_code(attempt, code)
  end

  private

  def set_code_field(panel, value)
    page.execute_script(<<~JS, panel, value)
      const field = document.querySelector(arguments[0] + " input[name='code']")
      field.value = arguments[1]
      field.dispatchEvent(new Event("input", { bubbles: true }))
    JS
  end

  # Patch window.fetch to tally calls to the login_status endpoint so the test
  # can confirm the poller is genuinely ticking (a dead poller would also leave
  # the field intact, masking the regression). A poll already in flight when this
  # installs is not tallied; under-counting is fine — the test only needs to
  # observe that ticks happened, which it still reaches.
  def instrument_poll_counter(status_path)
    page.execute_script(<<~JS, status_path)
      const target = arguments[0]
      window.__loginPolls = 0
      const original = window.fetch
      window.fetch = function(input) {
        const url = typeof input === "string" ? input : (input && input.url)
        if (url && url.indexOf(target) !== -1) window.__loginPolls += 1
        return original.apply(this, arguments)
      }
    JS
  end

  def wait_for_poll_count(target)
    deadline = Time.now + 12
    loop do
      return if page.evaluate_script("window.__loginPolls || 0") >= target
      raise "login poller never reached #{target} ticks" if Time.now > deadline
      sleep 0.2
    end
  end

  # The Submit POST is an async Turbo request; retry the DB read until the code
  # lands (or fail loudly with what we actually got).
  def assert_pasted_code(attempt, code)
    deadline = Time.now + 8
    loop do
      return if attempt.reload.pasted_code == code
      flunk "expected pasted_code to reach the backend, got #{attempt.pasted_code.inspect}" if Time.now > deadline
      sleep 0.2
    end
  end

  def stub_claude_path(const, value)
    ClaudeAuthProvider.send(:remove_const, const)
    ClaudeAuthProvider.const_set(const, value)
  end
end
