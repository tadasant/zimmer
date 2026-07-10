# frozen_string_literal: true

# Drives one runtime's interactive login CLI for the UI-driven "Authenticate"
# flow on the Quotas screen. A driver is a stateless strategy object: it knows
# the CLI command to spawn, the environment that isolates that CLI to a scratch
# config dir, how to recognize the verification URL/code in the CLI's live
# output, and how to capture the resulting tokens into a ClaudeAccount.
#
# The actual subprocess lifecycle (PTY spawn, output pump, stdin paste, status
# transitions) lives in RuntimeLoginJob — drivers stay pure so they can be
# unit-tested against captured CLI output fixtures without spawning anything.
#
# Subclasses: ClaudeLoginDriver (:paste completion — user pastes an auth code
# back), CodexLoginDriver (:poll completion — fully background device-auth).
class RuntimeLoginDriver
  # Strips ANSI escape sequences (cursor moves, colors, screen clears) the login
  # CLIs emit so verification URLs/codes can be matched against clean text.
  ANSI_ESCAPE = /\e\[[0-9;?]*[A-Za-z]/

  class << self
    def for(runtime)
      case runtime
      when ClaudeAuthProvider::RUNTIME then ClaudeLoginDriver.new
      when CodexAuthProvider::RUNTIME then CodexLoginDriver.new
      else raise ArgumentError, "Unknown runtime for login: #{runtime.inspect}"
      end
    end
  end

  # Removes ANSI control sequences and carriage returns from a raw CLI buffer.
  def strip_ansi(text)
    text.to_s.gsub(ANSI_ESCAPE, "").tr("\r", "\n")
  end

  # The argv (excluding the resolved executable) for the login command.
  # Subclasses override #subcommand; the executable is resolved separately so we
  # can try several install locations.
  def command
    raise NotImplementedError
  end

  # The first existing executable from #executable_candidates. Raises a clear
  # error when none is installed on the worker, rather than letting a bare-name
  # spawn surface as an opaque Errno::ENOENT.
  def resolved_command
    exe = executable_candidates.find { |c| c.include?("/") ? File.executable?(c) : which(c) }
    raise "login CLI not found on worker (looked for: #{executable_candidates.join(", ")})" unless exe
    [ exe, *command ]
  end

  # Environment overrides that point the CLI at an isolated scratch config dir so
  # an in-progress login never touches the live ~/.codex or ~/.claude until we
  # explicitly capture from it.
  def env(config_dir)
    raise NotImplementedError
  end

  # Parse a cleaned (ANSI-stripped) output buffer, returning whatever
  # verification details are present so far: { url:, code: }. Either may be nil
  # until the CLI has printed it.
  def parse_verification(_clean_buffer)
    raise NotImplementedError
  end

  # :poll  — login completes on its own once the user authorizes in the browser
  #          (Codex device-auth). The job just waits for the process to exit.
  # :paste — the CLI blocks waiting for an authorization code the user pastes
  #          back (Claude). The job writes attempt.pasted_code to the CLI stdin.
  def completion_mode
    raise NotImplementedError
  end

  # (:paste only) Regex marking the point in the output where the CLI is ready to
  # receive the pasted code, used to flip the attempt to awaiting_code.
  def paste_prompt
    nil
  end

  # Read the scratch config dir the CLI just wrote and persist the captured
  # credentials onto the account. Raises on identity mismatch or missing tokens.
  # @return [void]
  def capture!(_config_dir, _account)
    raise NotImplementedError
  end

  # True once the login CLI has written usable credentials into the scratch
  # config dir, letting the job capture them without waiting for the CLI process
  # to exit. Defaults to false; a :paste runtime whose CLI keeps its interactive
  # TUI open after a successful code paste (Claude) overrides this so completion
  # doesn't hinge on a PTY EOF that may never arrive. @return [Boolean]
  def credentials_ready?(_config_dir)
    false
  end

  # Extract the CLI's own failure explanation from its (ANSI-stripped) output so a
  # login that ends without usable credentials reports WHY instead of a generic
  # "did not produce credentials". The login CLIs print a human-readable reason
  # ("Login failed: getaddrinfo ESERVFAIL platform.claude.com", "Invalid code",
  # an expired-code notice) right before they give up; surfacing it turns an
  # undiagnosable failure into an actionable one in the Quotas login panel.
  # Returns a short trimmed string, or nil when the buffer has no recognizable
  # failure line (so we never surface the verification URL/prompt as a "reason").
  # @return [String, nil]
  def login_failure_hint(_clean_buffer)
    nil
  end

  private

  # Candidate executable paths/names, most-specific first.
  def executable_candidates
    raise NotImplementedError
  end

  # Minimal PATH lookup for a bare command name.
  def which(cmd)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
      File.executable?(File.join(dir, cmd))
    end
  end
end
