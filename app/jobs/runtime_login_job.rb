# frozen_string_literal: true

require "pty"
require "tmpdir"

# Runs one UI-driven login ("Authenticate" on the Quotas screen) to completion
# in the worker, where the runtime's credential filesystem lives.
#
# It spawns the runtime's login CLI under a PTY (the CLIs render an interactive
# TUI and won't emit the verification URL unless they believe they own a
# terminal), pumps the live output, and uses the RuntimeLoginAttempt row as a
# cross-container message bus:
#
#   * worker → UI: the parsed verification URL/code and status transitions
#   * UI → worker: the Claude authorization code the user pastes back, and
#                  cancellation
#
# The CLI writes into a throwaway CLAUDE_CONFIG_DIR / CODEX_HOME so an
# in-progress (or failed) login never disturbs the worker's active credentials.
# On success the driver captures the scratch credentials onto the account; the
# user then activates it through the existing Switch flow.
class RuntimeLoginJob < ApplicationJob
  queue_as :default

  # Hard ceiling on how long we hold the CLI subprocess open, independent of the
  # attempt's expires_at (which is the user-facing verification window). Keeps a
  # wedged CLI from pinning a worker thread forever.
  MAX_DURATION = 12.minutes

  # How often we poll the DB for user input (pasted code) and cancellation while
  # pumping CLI output.
  POLL_INTERVAL = 1.0

  # How often we stamp attempt.heartbeat_at while the loop is running. This is
  # the liveness signal CleanupRuntimeLoginAttemptsJob and QuotasController#
  # login_status use to notice that the worker driving a login has gone away —
  # a hard kill (deploy SIGKILL, crash, container replacement) skips Ruby
  # entirely, so no ensure block and no rescue will ever mark the row terminal.
  # Throttled well below POLL_INTERVAL so a 12-minute login costs ~48 writes
  # rather than ~720. Must stay comfortably under
  # RuntimeLoginAttempt::HEARTBEAT_TIMEOUT.
  HEARTBEAT_INTERVAL = 15.seconds

  def perform(attempt_id)
    attempt = RuntimeLoginAttempt.find_by(id: attempt_id)
    return unless attempt
    return if attempt.terminal?

    account = attempt.claude_account
    # The account was deleted while this login was queued or in flight. The
    # attempt row survives that delete (it is the account's history), but there
    # is nothing left to capture credentials into — resolve it terminally rather
    # than driving a CLI whose output has nowhere to go.
    return account_deleted!(attempt) if attempt.detached?

    driver = RuntimeLoginDriver.for(attempt.runtime)
    config_dir = Dir.mktmpdir("runtime-login-#{attempt.runtime}-")

    run(attempt, account, driver, config_dir)
  ensure
    FileUtils.remove_entry(config_dir) if config_dir && File.directory?(config_dir)
  end

  private

  # Terminal state for an attempt whose account is gone. Also drops the pasted
  # authorization code, which is credential-adjacent and single-use — and the
  # detached row outlives the account precisely so it can be read later.
  def account_deleted!(attempt)
    attempt.update!(
      status: "failed",
      error_message: "The account this login was for was deleted before the login completed.",
      pasted_code: nil
    )
  end

  def run(attempt, account, driver, config_dir)
    reader, writer, pid = PTY.spawn(driver.env(config_dir), *driver.resolved_command)
    attempt.update!(pid: pid, status: "starting", heartbeat_at: Time.current)
    @last_beat_at = Time.current

    raw = +""
    surfaced_url = false
    awaiting_code = false
    deadline = monotonic_now + MAX_DURATION

    loop do
      # Stop conditions driven by the UI side of the bus.
      state = poll_state(attempt)

      # Stop the moment the row is gone or already terminal — not just on
      # "canceled". Something else (the user cancelling, the reaper deciding this
      # attempt was orphaned, the row being pruned) has already decided the
      # outcome. Carrying on would let a late capture
      # resurrect a terminal row to "succeeded", overwriting the outcome the user
      # was shown with a contradictory one.
      break finish_settled(attempt, pid, state&.first) if state.nil? || RuntimeLoginAttempt::TERMINAL_STATUSES.include?(state[0])

      beat(attempt)

      # Hard cap on subprocess lifetime, independent of the attempt's wall-clock
      # verification window (CleanupRuntimeLoginAttemptsJob enforces that). Keeps a
      # wedged CLI from pinning a worker thread until the worker recycles.
      if monotonic_now > deadline
        break finish(attempt, pid, "expired",
          "The login CLI ran for #{MAX_DURATION.inspect} without completing and was stopped. Start a new login.")
      end

      # The :paste login CLI (Claude) keeps its interactive TUI open after a
      # successful code paste, so a PTY EOF may never come. The moment it writes
      # usable credentials into the scratch dir, capture them directly rather than
      # waiting for an exit that won't happen. EOF (below) stays as the fallback
      # for CLIs that do exit on completion.
      if driver.credentials_ready?(config_dir)
        return complete(attempt, account, driver, config_dir, pid, raw)
      end

      ready = IO.select([ reader ], nil, nil, POLL_INTERVAL)

      if ready
        begin
          raw << reader.read_nonblock(4096)
        rescue IO::WaitReadable
          # Spurious wakeup — nothing to read yet.
        rescue Errno::EIO, EOFError
          # PTY child exited; capture whatever it wrote.
          return complete(attempt, account, driver, config_dir, pid, raw)
        end
      end

      clean = driver.strip_ansi(raw)

      unless surfaced_url
        details = driver.parse_verification(clean)
        if details[:url].present?
          attempt.update!(
            verification_url: details[:url],
            verification_code: details[:code],
            status: "awaiting_user"
          )
          surfaced_url = true
        end
      end

      if driver.completion_mode == :paste
        if !awaiting_code && driver.paste_prompt && clean.match?(driver.paste_prompt)
          attempt.update!(status: "awaiting_code")
          awaiting_code = true
        end

        if awaiting_code && state && state[1].present?
          writer.write("#{state[1].strip}\n")
          writer.flush
          # Consume the single-use code and signal token exchange is underway.
          # The code must be nulled straight to the DB: the controller wrote it
          # from a separate process *after* this job loaded `attempt`, so the
          # in-memory row still has pasted_code=nil. attempt.update!(pasted_code:
          # nil) would be a dirty-tracking no-op (nil→nil) and silently leave the
          # spent code in the row. clear_pasted_code issues update_all, which
          # always writes.
          clear_pasted_code(attempt)
          attempt.update!(status: "completing")
          awaiting_code = false
          # Discard the buffered prompt so its stale "Paste code here" text can't
          # re-trigger awaiting_code on the next pass. A genuinely-rejected code
          # makes the CLI reprint the prompt into the now-empty buffer, which
          # legitimately re-arms the awaiting_code transition above for a retry.
          raw = +""
        end
      end

      break finish(attempt, pid, "failed", "Login process is no longer running.") unless process_alive?(pid)
    end
  rescue => e
    finish(attempt, pid, "failed", "Login error: #{e.class}")
    Rails.logger.warn "[RuntimeLoginJob] attempt=#{attempt.id} error: #{e.class} - #{e.message}"
  ensure
    # Guarantee the login CLI is reaped no matter how the loop unwound — a normal
    # break already terminated it (no-op here), but an uncaught error or a worker
    # interrupt (GoodJob raises on SIGTERM, ApplicationJob discards it) would
    # otherwise orphan the process. terminate is idempotent and guarded.
    terminate(pid)
    close_io(reader, writer)
  end

  # Read the UI side of the message bus (pasted code + cancellation). The
  # `uncached` block this requires is owned by RuntimeLoginAttempt.bus_state so
  # no call site can forget it — see that method for why it is mandatory.
  def poll_state(attempt)
    RuntimeLoginAttempt.bus_state(attempt.id)
  end

  # Stamp the liveness signal the reaper and the Quotas poller read. Throttled to
  # HEARTBEAT_INTERVAL, and issued straight to the DB (update_all) so it neither
  # disturbs the in-memory row nor depends on its dirty state.
  #
  # Best-effort: a transient DB hiccup here must not abort a login that is
  # otherwise fine. Missing a beat only risks an early reap, and the reaper's
  # timeout leaves several beats of slack.
  def beat(attempt)
    now = Time.current
    return if @last_beat_at && now - @last_beat_at < HEARTBEAT_INTERVAL

    RuntimeLoginAttempt.where(id: attempt.id).update_all(heartbeat_at: now)
    @last_beat_at = now
  rescue => e
    Rails.logger.warn "[RuntimeLoginJob] attempt=#{attempt.id} heartbeat failed: #{e.class} - #{e.message}"
  end

  # Capture the credentials the CLI wrote into the scratch config dir. Reached
  # either because the CLI exited (PTY EOF) or because it wrote usable
  # credentials while keeping its TUI open (proactive capture). Must not block on
  # the process: a still-running CLI is terminated and reaped by run()'s ensure.
  #
  # `raw` is the CLI's accumulated PTY output; on failure we mine it for the CLI's
  # own reason (e.g. "Login failed: getaddrinfo ESERVFAIL platform.claude.com")
  # so the Quotas panel shows why the login died instead of the opaque generic
  # "did not produce credentials".
  def complete(attempt, account, driver, config_dir, pid, raw = nil)
    driver.capture!(config_dir, account)
    settle(attempt, "succeeded", nil)
    Rails.logger.info "[RuntimeLoginJob] attempt=#{attempt.id} runtime=#{attempt.runtime} succeeded"
  rescue => e
    message = enrich_error(e.message, driver, raw)
    settle(attempt, "failed", truncate_error(message))
    Rails.logger.warn "[RuntimeLoginJob] attempt=#{attempt.id} capture failed: #{e.class} - #{message}"
  end

  # Write this job's verdict, but only onto a row nobody else has settled.
  #
  # The loop's terminal-status guard runs at the top of an iteration; the capture
  # that follows it — including all of driver.capture! — is a window in which the
  # user can hit Cancel or the reaper can decide this attempt is orphaned. An
  # unconditional write would overwrite the outcome they were shown, so the status
  # filter goes in the UPDATE itself, where it is atomic. Losing the race is
  # normal, not an error: the row already says something true.
  #
  # Always drops the pasted authorization code. It is single-use and
  # credential-adjacent, and a double-submitted code can land in the row after the
  # loop consumed the first one, so no terminal path may leave it behind.
  def settle(attempt, status, message)
    updated = RuntimeLoginAttempt
      .where(id: attempt.id)
      .where.not(status: RuntimeLoginAttempt::TERMINAL_STATUSES)
      .update_all(status: status, error_message: message, pasted_code: nil, updated_at: Time.current)

    if updated.zero?
      clear_pasted_code(attempt)
      Rails.logger.info "[RuntimeLoginJob] attempt=#{attempt.id} settled elsewhere; not writing #{status}"
    end
    updated.positive?
  end

  # Append the CLI's own failure line to the capture error when one is present in
  # the output, so a network/DNS/token-exchange failure surfaces its real cause.
  def enrich_error(message, driver, raw)
    hint = driver.login_failure_hint(driver.strip_ansi(raw.to_s))
    hint.present? ? "#{message} — CLI reported: #{hint}" : message
  end

  def finish(attempt, pid, status, message)
    terminate(pid)
    settle(attempt, status, truncate_error(message))
  end

  # The attempt was settled by someone else while we were driving it (user
  # cancel, reaper, or the row cascading away with a deleted account). The
  # terminal status and its error_message are already written, so don't touch
  # them — just stop the CLI and drop any authorization code the user pasted.
  def finish_settled(attempt, pid, status)
    terminate(pid)
    clear_pasted_code(attempt)
    Rails.logger.info "[RuntimeLoginJob] attempt=#{attempt.id} already settled (#{status || "row deleted"}); stopping"
  end

  # Null the Claude authorization code on any terminal path so a failed/canceled
  # attempt never retains a credential-adjacent value. Issued straight to the DB
  # because the in-memory attempt (loaded at perform start) may not reflect a code
  # the controller wrote after the job began.
  def clear_pasted_code(attempt)
    RuntimeLoginAttempt.where(id: attempt.id).update_all(pasted_code: nil)
  end

  def process_alive?(pid)
    return false unless pid
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  def terminate(pid)
    return unless pid && process_alive?(pid)
    Process.kill("TERM", pid)
    safe_wait(pid)
  rescue Errno::ESRCH
    # Already gone.
  end

  def safe_wait(pid)
    Process.wait2(pid)
  rescue Errno::ECHILD
    [ pid, nil ]
  end

  def close_io(*ios)
    ios.each do |io|
      io&.close
    rescue IOError
      # Already closed.
    end
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def truncate_error(message)
    message.to_s[0, 500]
  end
end
