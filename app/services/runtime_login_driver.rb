# frozen_string_literal: true

# Drives one runtime's interactive login CLI for the UI-driven "Authenticate"
# flow on the Inference screen. A driver is a stateless strategy object: it knows
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
  # An OSC (Operating System Command) sequence ends at BEL or at ST (ESC \).
  OSC_TERMINATOR = /(?:\a|\e\\)/
  # OSC 8 hyperlink: `ESC ] 8 ; params ; URI <term> visible text ESC ] 8 ; ; <term>`.
  # Capture group 1 is the link target — empty for the closing sequence, which
  # therefore drops out entirely rather than leaving a stray line break behind.
  OSC_HYPERLINK = /\e\]8;[^;\a\e]*;([^\a\e]*)#{OSC_TERMINATOR}/
  # Any other OSC sequence (window title, clipboard, …) carries nothing we want.
  OSC_ESCAPE = /\e\][^\a\e]*#{OSC_TERMINATOR}/
  # An OSC sequence at the very end of the buffer whose terminator has not
  # arrived yet. The job re-parses a growing buffer every tick, so a chunk read
  # routinely cuts one in half — and a half-read hyperlink target is a half URL
  # that would otherwise be surfaced once and never revisited.
  UNTERMINATED_OSC = /\e\][^\a\e]*\z/
  # One character that may appear inside a URL in CLI output: anything that is
  # neither whitespace nor an ASCII control character. The control-character
  # exclusion is what keeps a greedy match from running through an escape-sequence
  # terminator (BEL, ESC) and on into whatever decoration the terminal renderer
  # wrapped around the link — the failure mode a plain `\S` has. Subclasses build
  # their URL patterns from it.
  URL_CHAR = /[^\s\x00-\x1f\x7f]/

  class << self
    def for(runtime)
      case runtime
      when ClaudeAuthProvider::RUNTIME then ClaudeLoginDriver.new
      when CodexAuthProvider::RUNTIME then CodexLoginDriver.new
      else raise ArgumentError, "Unknown runtime for login: #{runtime.inspect}"
      end
    end
  end

  # Turns a raw PTY buffer into the plain text a human would read on screen.
  #
  # Normalizing the encoding comes first, so everything downstream matches text
  # rather than raw bytes: PTY reads arrive binary and a chunk read can cut a
  # multibyte character in half, and this is the boundary where those bytes
  # become text that gets matched and written to the DB. The dup is what keeps a
  # caller's string safe from force_encoding, which mutates in place.
  #
  # OSC 8 hyperlinks are then unwrapped to their target rather than dropped. A
  # login CLI that renders its authorization link as a hyperlink emits the URL
  # twice — once as the escape sequence's target, once as the visible label —
  # and a stripper that deleted the whole sequence would depend on that label
  # still being the full URL. Terminals conventionally shorten hyperlink labels,
  # so keeping the target is what survives that drift; the duplicate the unwrap
  # leaves behind is harmless, since every consumer matches the first hit. The
  # target and the label are separated by a space rather than a newline, because
  # the failure-line patterns downstream are line-oriented (`[^\n]*`) and a break
  # injected mid-line would truncate what they report.
  def strip_ansi(text)
    text.to_s
      .dup
      .force_encoding(Encoding::UTF_8)
      .scrub("")
      .gsub(OSC_HYPERLINK) { $1.empty? ? "" : "#{$1} " }
      .gsub(OSC_ESCAPE, "")
      .sub(UNTERMINATED_OSC, "")
      .gsub(ANSI_ESCAPE, "")
      .tr("\r", "\n")
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
  # undiagnosable failure into an actionable one in the Inference login panel.
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
