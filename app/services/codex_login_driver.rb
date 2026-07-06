# frozen_string_literal: true

# Drives `codex login --device-auth` for the UI Authenticate flow.
#
# Device-auth is fully background-able: the CLI prints a verification URL and a
# one-time code, the user authorizes in their browser, and the CLI exchanges
# tokens and writes auth.json on its own — no input is ever piped back. We point
# CODEX_HOME at a scratch dir so the in-progress login can't clobber the live
# ~/.codex/auth.json; on success we read the scratch auth.json and store it.
class CodexLoginDriver < RuntimeLoginDriver
  # The verification URL the CLI prints (ChatGPT device-authorization page).
  URL_REGEX = %r{https://(?:auth\.openai\.com|chatgpt\.com)/\S*device\S*}
  # The one-time pairing code. The CLI renders it as a hyphenated upper-alnum
  # pair whose halves are not a fixed length (observed live: "Z0PC-EQL0R", a
  # 4-5 split), so the trailing half allows 4–8 chars. The leading half is
  # pinned to exactly 4 so the regex can't latch onto the date-stamped scratch
  # CODEX_HOME path the CLI echoes in its PATH warning (e.g. "20260601-18255").
  CODE_REGEX = /\b([A-Z0-9]{4}-[A-Z0-9]{4,8})\b/

  def command
    [ "login", "--device-auth" ]
  end

  def env(config_dir)
    { "CODEX_HOME" => config_dir }
  end

  def parse_verification(clean_buffer)
    {
      url: clean_buffer[URL_REGEX],
      code: clean_buffer[CODE_REGEX, 1]
    }
  end

  def completion_mode
    :poll
  end

  # Read the scratch auth.json the CLI wrote and store it verbatim under
  # oauth_config["auth_json"]. Codex device-auth has no pre-chosen identity to
  # match against (the account row is a placeholder until first login), so —
  # unlike Claude — we don't gate on email; we just require usable credentials.
  def capture!(config_dir, account)
    auth_path = File.join(config_dir, "auth.json")
    raise "codex login did not produce auth.json" unless File.exist?(auth_path)

    auth_json = JSON.parse(File.read(auth_path))
    tokens = auth_json["tokens"]
    has_oauth = tokens.is_a?(Hash) && tokens["refresh_token"].present?
    has_api_key = auth_json["OPENAI_API_KEY"].present?
    raise "codex auth.json is missing both OAuth tokens and an API key" unless has_oauth || has_api_key

    account.update!(oauth_config: { "auth_json" => auth_json }, status: :active)
  end

  private

  def executable_candidates
    [ "/usr/bin/codex", "/usr/local/bin/codex", "codex" ]
  end
end
