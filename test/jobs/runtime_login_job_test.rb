# frozen_string_literal: true

require "test_helper"
require "pty"

class RuntimeLoginJobTest < ActiveJob::TestCase
  # A driver whose "CLI" is a tiny shell script: it prints a verification URL,
  # then exits. On exit the job calls capture!, which we satisfy by writing the
  # account's credentials directly. This exercises the real PTY pump, URL
  # surfacing, EOF detection, and capture path without a real login CLI.
  class FakePollDriver < RuntimeLoginDriver
    SCRIPT = 'printf "Open https://auth.openai.com/codex/device?code=FAKE to sign in\\n"; sleep 0.3'

    def resolved_command
      [ "/bin/sh", "-c", SCRIPT ]
    end

    def env(_dir) = {}

    def parse_verification(clean)
      { url: clean[%r{https://\S+device\S*}], code: nil }
    end

    def completion_mode = :poll

    def capture!(_config_dir, account)
      account.update!(status: :active, oauth_config: { "auth_json" => { "OPENAI_API_KEY" => "sk-fake" } })
    end
  end

  # A Claude-style :paste driver. Its "CLI" prints a URL, prints the paste prompt,
  # then reads one line from stdin and exits 0 only if the pasted code is correct
  # (writing a sentinel the capture step keys off of). Exercises the real stdin
  # write, the awaiting_code transition, and the success/failure capture branches.
  class FakePasteDriver < RuntimeLoginDriver
    def initialize(sentinel_dir)
      @sentinel_dir = sentinel_dir
    end

    def resolved_command
      sentinel = File.join(@sentinel_dir, "ok")
      script = <<~SH
        printf 'Open https://platform.claude.com/oauth/authorize?x=1\\n'
        printf 'Paste code here:\\n'
        read code
        if [ "$code" = "good-code" ]; then : > "#{sentinel}"; exit 0; else exit 1; fi
      SH
      [ "/bin/sh", "-c", script ]
    end

    def env(_dir) = {}
    def completion_mode = :paste
    def paste_prompt = /Paste code here/

    def parse_verification(clean)
      { url: clean[%r{https://\S+oauth\S*}], code: nil }
    end

    def capture!(_config_dir, account)
      raise "login did not produce credentials" unless File.exist?(File.join(@sentinel_dir, "ok"))
      account.update!(status: :active, oauth_config: { "credentials_json" => { "ok" => true } })
    end
  end

  # A Claude-style :paste driver whose "CLI" reproduces the real
  # `claude auth login --claudeai` behavior the EOF-only completion path missed:
  # on a good code it writes the credentials file and then KEEPS RUNNING (its TUI
  # stays open — no exit, so no PTY EOF). The job must capture as soon as the
  # credentials land via credentials_ready?, not wait for an exit that never
  # comes. Drives the actual regression #4013's proof never exercised.
  class FakeNonExitingPasteDriver < RuntimeLoginDriver
    def initialize(creds_dir)
      @creds_dir = creds_dir
    end

    def creds_path = File.join(@creds_dir, ".credentials.json")

    def resolved_command
      script = <<~SH
        printf 'Open https://platform.claude.com/oauth/authorize?x=1\\n'
        printf 'Paste code here:\\n'
        read code
        if [ "$code" = "good-code" ]; then
          printf '{"claudeAiOauth":{"accessToken":"at","refreshToken":"rt"}}' > "#{creds_path}"
          printf 'Login successful!\\n'
          sleep 60
        fi
      SH
      [ "/bin/sh", "-c", script ]
    end

    def env(_dir) = {}
    def completion_mode = :paste
    def paste_prompt = /Paste code here/

    def parse_verification(clean)
      { url: clean[%r{https://\S+oauth\S*}], code: nil }
    end

    def credentials_ready?(_config_dir)
      File.exist?(creds_path)
    end

    def capture!(_config_dir, account)
      creds = JSON.parse(File.read(creds_path))
      raise "no credentials" if creds.dig("claudeAiOauth", "accessToken").blank?
      account.update!(status: :active, oauth_config: { "credentials_json" => creds })
    end
  end

  # A :paste driver whose "CLI" prints a token-exchange failure line and exits
  # WITHOUT writing credentials — the shape of the real prod failure where the
  # Claude CLI can't reach platform.claude.com (getaddrinfo ESERVFAIL) and gives
  # up. capture! raises "did not produce credentials"; the job must enrich that
  # with the CLI's own reason via login_failure_hint (delegated to the real
  # ClaudeLoginDriver extraction here) so the panel shows the true cause.
  class FakeExchangeFailurePasteDriver < RuntimeLoginDriver
    def resolved_command
      script = <<~SH
        printf 'Open https://platform.claude.com/oauth/authorize?x=1\\n'
        printf 'Paste code here:\\n'
        read code
        printf 'Login failed: getaddrinfo ESERVFAIL platform.claude.com\\n'
        exit 1
      SH
      [ "/bin/sh", "-c", script ]
    end

    def env(_dir) = {}
    def completion_mode = :paste
    def paste_prompt = /Paste code here/

    def parse_verification(clean)
      { url: clean[%r{https://\S+oauth\S*}], code: nil }
    end

    def login_failure_hint(clean_buffer) = ClaudeLoginDriver.new.login_failure_hint(clean_buffer)

    def capture!(_config_dir, _account)
      raise "claude login did not produce credentials"
    end
  end

  setup do
    @account = ClaudeAccount.create!(
      email: "runtime-login-job@example.com", runtime: "codex",
      status: :needs_reauth, is_current: false, priority: 60, oauth_config: {}
    )
  end

  test "no-op when the attempt does not exist" do
    assert_nothing_raised { RuntimeLoginJob.perform_now(-1) }
  end

  test "no-op when the attempt is already terminal" do
    attempt = @account.runtime_login_attempts.create!(runtime: "codex", status: "canceled")
    # A terminal attempt must never spawn a process; PTY.spawn would blow up if it did.
    RuntimeLoginJob.perform_now(attempt.id)
    assert_equal "canceled", attempt.reload.status
    assert_nil attempt.pid
  end

  test "happy path: surfaces the URL, captures credentials, and marks succeeded" do
    attempt = @account.runtime_login_attempts.create!(runtime: "codex")

    RuntimeLoginDriver.stub(:for, FakePollDriver.new) do
      RuntimeLoginJob.perform_now(attempt.id)
    end

    attempt.reload
    assert_equal "succeeded", attempt.status
    assert_equal "https://auth.openai.com/codex/device?code=FAKE", attempt.verification_url
    assert_nil attempt.error_message

    @account.reload
    assert @account.active?
    assert_equal "sk-fake", @account.oauth_config.dig("auth_json", "OPENAI_API_KEY")
  end

  test "paste path: writes the pasted code to stdin, captures, and marks succeeded" do
    Dir.mktmpdir do |dir|
      claude = ClaudeAccount.create!(
        email: "runtime-login-job-paste@example.com", runtime: "claude_code",
        status: :needs_reauth, is_current: false, priority: 61, oauth_config: {}
      )
      attempt = claude.runtime_login_attempts.create!(runtime: "claude_code", pasted_code: "good-code")

      RuntimeLoginDriver.stub(:for, FakePasteDriver.new(dir)) do
        RuntimeLoginJob.perform_now(attempt.id)
      end

      attempt.reload
      assert_equal "succeeded", attempt.status
      assert_equal "https://platform.claude.com/oauth/authorize?x=1", attempt.verification_url
      assert_nil attempt.pasted_code, "single-use pasted code must be consumed"
      assert claude.reload.active?
    end
  end

  test "paste path: a CLI that rejects the code and exits non-zero ends failed" do
    Dir.mktmpdir do |dir|
      claude = ClaudeAccount.create!(
        email: "runtime-login-job-badcode@example.com", runtime: "claude_code",
        status: :needs_reauth, is_current: false, priority: 62, oauth_config: {}
      )
      attempt = claude.runtime_login_attempts.create!(runtime: "claude_code", pasted_code: "bad-code")

      RuntimeLoginDriver.stub(:for, FakePasteDriver.new(dir)) do
        RuntimeLoginJob.perform_now(attempt.id)
      end

      assert_equal "failed", attempt.reload.status
      assert_nil attempt.pasted_code
      assert_not claude.reload.active?
    end
  end

  test "paste path: a failed capture surfaces the CLI's own error reason" do
    claude = ClaudeAccount.create!(
      email: "runtime-login-job-exchange-fail@example.com", runtime: "claude_code",
      status: :needs_reauth, is_current: false, priority: 63, oauth_config: {}
    )
    attempt = claude.runtime_login_attempts.create!(runtime: "claude_code", pasted_code: "some-code")

    RuntimeLoginDriver.stub(:for, FakeExchangeFailurePasteDriver.new) do
      RuntimeLoginJob.perform_now(attempt.id)
    end

    attempt.reload
    assert_equal "failed", attempt.status
    assert_match "did not produce credentials", attempt.error_message
    assert_match "CLI reported: Login failed: getaddrinfo ESERVFAIL platform.claude.com",
      attempt.error_message
    assert_not claude.reload.active?
  end

  test "paste path: captures as soon as credentials land, without waiting for the CLI to exit" do
    Dir.mktmpdir do |dir|
      claude = ClaudeAccount.create!(
        email: "runtime-login-job-nonexit@example.com", runtime: "claude_code",
        status: :needs_reauth, is_current: false, priority: 63, oauth_config: {}
      )
      attempt = claude.runtime_login_attempts.create!(runtime: "claude_code", pasted_code: "good-code")

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      RuntimeLoginDriver.stub(:for, FakeNonExitingPasteDriver.new(dir)) do
        RuntimeLoginJob.perform_now(attempt.id)
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      attempt.reload
      assert_equal "succeeded", attempt.status, "must capture from the non-exiting CLI"
      assert_nil attempt.pasted_code, "single-use pasted code must be consumed"
      assert claude.reload.active?
      assert_equal "at", claude.oauth_config.dig("credentials_json", "claudeAiOauth", "accessToken")
      # The fake CLI sleeps 60s after writing creds; proactive capture must not
      # block on that. Generous bound to stay non-flaky under CI load while still
      # proving we didn't wait out the sleep (or MAX_DURATION).
      assert elapsed < 30, "expected proactive capture, but the job blocked for #{elapsed.round(1)}s"
    end
  end

  # Regression for the login hang: the job runs inside ActiveJob's pool-level
  # query cache, and the controller writes pasted_code from a *separate* web
  # process whose pool never busts the worker's cache. If the poll read is served
  # from that cache, the worker never observes the pasted code and the login hangs
  # at awaiting_code until it times out. poll_state must bypass the cache.
  #
  # The pre-existing "paste path" tests can't catch this: they set pasted_code at
  # attempt creation, so the job's first poll reads the real value and there is no
  # stale-cache window. This test recreates the window by priming the cache first.
  test "poll_state bypasses the query cache so a cross-process pasted code is observed" do
    claude = ClaudeAccount.create!(
      email: "runtime-login-job-uncached@example.com", runtime: "claude_code",
      status: :needs_reauth, is_current: false, priority: 64, oauth_config: {}
    )
    attempt = claude.runtime_login_attempts.create!(runtime: "claude_code", status: "awaiting_code")
    job = RuntimeLoginJob.new

    RuntimeLoginAttempt.cache do
      # Prime the per-connection query cache with this row's poll SQL, exactly as
      # the loop's first iterations do.
      RuntimeLoginAttempt.where(id: attempt.id).pick(:status, :pasted_code)

      # Guard: the cache is genuinely active — a plain repeat pick is served as a
      # cache hit. Without this, the regression below would be meaningless.
      assert served_from_query_cache?(/runtime_login_attempts/) {
        RuntimeLoginAttempt.where(id: attempt.id).pick(:status, :pasted_code)
      }, "guard: the query cache must be active for this regression to be meaningful"

      # The fix: poll_state must NOT be served from the cache, so a pasted_code
      # written after the cache was primed (cross-process, in production) is seen.
      assert_not served_from_query_cache?(/runtime_login_attempts/) {
        job.send(:poll_state, attempt)
      }, "poll_state must bypass the query cache (regression for the login hang)"
    end
  end

  # Regression: on a successful paste login the spent single-use code must be
  # nulled in the DB. The controller writes pasted_code from a *separate* process
  # *after* this job loaded the attempt, so the job's in-memory row still has
  # pasted_code=nil. attempt.update!(pasted_code: nil) is then a dirty-tracking
  # no-op (nil -> nil) that silently leaves the spent code in the row; the consume
  # site must null it straight to the DB (clear_pasted_code -> update_all).
  #
  # The "paste path" tests above can't catch this: they set pasted_code at attempt
  # creation, so the job's in-memory row tracks it and update! works. This test
  # recreates the cross-process window where the in-memory row never saw the code.
  test "consuming the pasted code nulls it in the DB even when the job's in-memory row never saw it" do
    claude = ClaudeAccount.create!(
      email: "runtime-login-job-consume@example.com", runtime: "claude_code",
      status: :needs_reauth, is_current: false, priority: 65, oauth_config: {}
    )
    attempt = claude.runtime_login_attempts.create!(runtime: "claude_code", status: "awaiting_code")

    # The job's in-memory copy, loaded before the user pasted: pasted_code nil.
    loaded = RuntimeLoginAttempt.find(attempt.id)
    assert_nil loaded.pasted_code

    # Controller (separate process) writes the code straight to the DB.
    RuntimeLoginAttempt.where(id: attempt.id).update_all(pasted_code: "spent-code")

    # Guard: the buggy form does NOT clear it — in-memory nil -> nil is not dirty,
    # so ActiveRecord omits the column from the UPDATE. This is the trap.
    loaded.update!(pasted_code: nil)
    assert_equal "spent-code", attempt.reload.pasted_code,
      "guard: attempt.update!(pasted_code: nil) is a dirty-tracking no-op in the cross-process window"

    # The job's actual consume path nulls it straight to the DB via update_all.
    RuntimeLoginJob.new.send(:clear_pasted_code, loaded)
    assert_nil attempt.reload.pasted_code, "spent single-use code must be nulled in the DB after consume"
  end

  test "canceling terminates the live CLI process and drops the pasted code" do
    attempt = @account.runtime_login_attempts.create!(
      runtime: "claude_code", status: "awaiting_code", pasted_code: "secret-code"
    )
    reader, writer, pid = PTY.spawn("/bin/sh", "-c", "sleep 30")
    attempt.update!(pid: pid)
    assert process_alive?(pid), "sanity: spawned CLI should be running"

    RuntimeLoginJob.new.send(:finish_canceled, attempt, pid)

    assert_not process_alive?(pid), "canceled login CLI must be terminated"
    assert_nil attempt.reload.pasted_code, "credential-adjacent pasted code must be dropped on cancel"
  ensure
    [ reader, writer ].each { |io| io&.close rescue IOError }
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  # Did running the block serve any SQL matching the pattern from the query cache?
  # ActiveRecord instruments cache hits with cached: true on sql.active_record.
  def served_from_query_cache?(sql_pattern)
    hit = false
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      payload = args.last
      hit = true if payload[:cached] && payload[:sql].to_s.match?(sql_pattern)
    end
    yield
    hit
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end
end
