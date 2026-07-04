# frozen_string_literal: true

# Drives `claude auth login --claudeai` for the UI Authenticate flow.
#
# Unlike Codex device-auth, the Claude CLI cannot complete on its own: it prints
# an OAuth authorization URL, then blocks on a "Paste code here if prompted >"
# stdin prompt. The user authorizes in their browser, copies the resulting code,
# and pastes it into the UI; RuntimeLoginJob writes it to the held-open CLI's
# stdin. We point CLAUDE_CONFIG_DIR at a scratch dir so the login writes its
# identity/credentials there instead of clobbering the worker's live ~/.claude.
class ClaudeLoginDriver < RuntimeLoginDriver
  # The OAuth authorization URL the CLI prints. --claudeai (subscription) emits a
  # claude.com/cai/oauth/authorize URL; the --console (API billing) variant emits
  # platform.claude.com/oauth/authorize. Match both so the driver is robust to
  # either default.
  URL_REGEX = %r{https://(?:claude\.com/cai|platform\.claude\.com)/oauth/authorize\?\S+}
  # The CLI's stdin prompt that signals it is ready for the pasted auth code.
  PASTE_PROMPT = /Paste code here/i

  def command
    [ "auth", "login", "--claudeai" ]
  end

  def env(config_dir)
    { "CLAUDE_CONFIG_DIR" => config_dir }
  end

  def parse_verification(clean_buffer)
    { url: clean_buffer[URL_REGEX], code: nil }
  end

  def completion_mode
    :paste
  end

  def paste_prompt
    PASTE_PROMPT
  end

  # Read the scratch config dir the CLI populated and store the credentials.
  # Gated by a strict identity check: the email the CLI authenticated as must
  # equal the account's email, so a user can't accidentally attach the wrong
  # subscription to a pool row. Mirrors ClaudeAccount.sync_from_filesystem!'s
  # shape — oauth_config = { "claude_json" => ..., "credentials_json" => ... }.
  def capture!(config_dir, account)
    credentials_path = credentials_path_in(config_dir)
    raise "claude login did not produce credentials" unless credentials_path && File.exist?(credentials_path)

    credentials_json = JSON.parse(File.read(credentials_path))
    claude_json_path = File.join(config_dir, ".claude.json")
    claude_json = File.exist?(claude_json_path) ? JSON.parse(File.read(claude_json_path)) : {}

    captured_email = extract_email(claude_json)
    if captured_email.present? && captured_email.casecmp?(account.email) == false
      raise "claude login authenticated as #{captured_email}, expected #{account.email}"
    end

    unless complete_oauth?(credentials_json)
      raise "claude login credentials are incomplete (missing accessToken or refreshToken)"
    end

    account.update!(
      oauth_config: { "claude_json" => claude_json, "credentials_json" => credentials_json },
      status: :active
    )
  end

  # The Claude CLI keeps its interactive TUI open after a successful code paste
  # ("Login successful!" without exiting), so the login job can't rely on a PTY
  # EOF to know it's done. It instead watches for the credentials file landing in
  # the scratch dir with a usable OAuth token pair — exactly the precondition
  # capture! needs — and captures as soon as it appears.
  #
  # It also requires the identity file (.claude.json carrying an email) to be
  # present, so capture!'s email-identity guard is actually exercised on the
  # proactive path. The old EOF path got this for free because the CLI had fully
  # exited by then; firing the instant .credentials.json lands could otherwise
  # capture in the window before the identity write and silently skip the
  # "authenticated as X, expected Y" check that keeps the wrong subscription from
  # attaching to a pool row.
  def credentials_ready?(config_dir)
    path = credentials_path_in(config_dir)
    return false unless path
    return false unless complete_oauth?(JSON.parse(File.read(path)))

    identity_email(config_dir).present?
  rescue JSON::ParserError, Errno::ENOENT
    # A file is mid-write (or vanished); treat as not-ready and retry next tick.
    false
  end

  private

  # The email the CLI authenticated as, read from the scratch .claude.json the
  # login writes alongside the credentials. nil until that identity file lands.
  def identity_email(config_dir)
    claude_json_path = File.join(config_dir, ".claude.json")
    return nil unless File.exist?(claude_json_path)
    extract_email(JSON.parse(File.read(claude_json_path)))
  end

  # A credentials_json holds a complete, usable subscription token pair. Delegates
  # to the single completeness invariant so the login boundary and the
  # token-persistence paths can never disagree on what "complete" means. Tolerant
  # of a non-object top-level value (a polling predicate must never raise).
  def complete_oauth?(credentials_json)
    ClaudeAccount.complete_claude_oauth?(credentials_json)
  end

  # CLAUDE_CONFIG_DIR layouts differ across CLI versions: some write
  # .credentials.json directly into the config dir, others nest it under
  # .claude/. Probe both.
  def credentials_path_in(config_dir)
    [
      File.join(config_dir, ".credentials.json"),
      File.join(config_dir, ".claude", ".credentials.json")
    ].find { |p| File.exist?(p) }
  end

  def extract_email(claude_json)
    oauth_account = claude_json["oauthAccount"]
    return nil if oauth_account.blank?
    oauth_account.is_a?(Hash) ? oauth_account["emailAddress"] : oauth_account
  end

  def executable_candidates
    [ "/home/rails/.local/bin/claude", File.join(Dir.home, ".local/bin/claude"), "claude" ]
  end
end
