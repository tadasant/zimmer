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

  def perform(attempt_id)
    attempt = RuntimeLoginAttempt.find_by(id: attempt_id)
    return unless attempt
    return if attempt.terminal?

    account = attempt.claude_account
    driver = RuntimeLoginDriver.for(attempt.runtime)
    config_dir = Dir.mktmpdir("runtime-login-#{attempt.runtime}-")

    run(attempt, account, driver, config_dir)
  ensure
    FileUtils.remove_entry(config_dir) if config_dir && File.directory?(config_dir)
  end

  private

  def run(attempt, account, driver, config_dir)
    reader, writer, pid = PTY.spawn(driver.env(config_dir), *driver.resolved_command)
    attempt.update!(pid: pid, status: "starting")

    raw = +""
    surfaced_url = false
    awaiting_code = false
    deadline = monotonic_now + MAX_DURATION

    loop do
      # Stop conditions driven by the UI side of the bus.
      state = poll_state(attempt)
      break finish_canceled(attempt, pid) if state.nil? || state[0] == "canceled"

      # Hard cap on subprocess lifetime, independent of the attempt's wall-clock
      # verification window (CleanupRuntimeLoginAttemptsJob enforces that). Keeps a
      # wedged CLI from pinning a worker thread until the worker recycles.
      if monotonic_now > deadline
        break finish(attempt, pid, "expired", "Login timed out before completion.")
      end

      # The :paste login CLI (Claude) keeps its interactive TUI open after a
      # successful code paste, so a PTY EOF may never come. The moment it writes
      # usable credentials into the scratch dir, capture them directly rather than
      # waiting for an exit that won't happen. EOF (below) stays as the fallback
      # for CLIs that do exit on completion.
      if driver.credentials_ready?(config_dir)
        return complete(attempt, account, driver, config_dir, pid)
      end

      ready = IO.select([ reader ], nil, nil, POLL_INTERVAL)

      if ready
        begin
          raw << reader.read_nonblock(4096)
        rescue IO::WaitReadable
          # Spurious wakeup — nothing to read yet.
        rescue Errno::EIO, EOFError
          # PTY child exited; capture whatever it wrote.
          return complete(attempt, account, driver, config_dir, pid)
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

  # Read the UI side of the message bus (pasted code + cancellation). MUST bypass
  # the ActiveRecord query cache.
  #
  # This job runs inside ActiveJob's query-cache scope, where the cache is
  # pool-level (Rails 7.1+). The loop polls the same row with identical SQL every
  # tick, so the first read caches pasted_code=nil and every subsequent read is
  # served from that cache. The user's code is written by the *controller* — a
  # separate web process with its own connection pool — whose write never
  # invalidates this worker pool's cache. Without uncached, the worker would never
  # observe the pasted code and the login would hang at awaiting_code until it
  # timed out. (The loop's own writes bust its cache, but they happen on stale
  # data and don't help.) uncached forces a fresh DB hit so cross-process writes
  # are seen.
  def poll_state(attempt)
    RuntimeLoginAttempt.uncached do
      RuntimeLoginAttempt.where(id: attempt.id).pick(:status, :pasted_code)
    end
  end

  # Capture the credentials the CLI wrote into the scratch config dir. Reached
  # either because the CLI exited (PTY EOF) or because it wrote usable
  # credentials while keeping its TUI open (proactive capture). Must not block on
  # the process: a still-running CLI is terminated and reaped by run()'s ensure.
  def complete(attempt, account, driver, config_dir, pid)
    driver.capture!(config_dir, account)
    attempt.update!(status: "succeeded", error_message: nil)
    Rails.logger.info "[RuntimeLoginJob] attempt=#{attempt.id} runtime=#{attempt.runtime} succeeded"
  rescue => e
    clear_pasted_code(attempt)
    attempt.update!(status: "failed", error_message: truncate_error(e.message))
    Rails.logger.warn "[RuntimeLoginJob] attempt=#{attempt.id} capture failed: #{e.class} - #{e.message}"
  end

  def finish(attempt, pid, status, message)
    terminate(pid)
    clear_pasted_code(attempt)
    attempt.update!(status: status, error_message: truncate_error(message))
  end

  def finish_canceled(attempt, pid)
    terminate(pid)
    # Status already "canceled" from the controller; just stop the process and
    # drop any authorization code the user pasted before cancelling.
    clear_pasted_code(attempt)
    Rails.logger.info "[RuntimeLoginJob] attempt=#{attempt.id} canceled by user"
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
