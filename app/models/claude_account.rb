# frozen_string_literal: true

# Represents an agent-runtime account in the rotation pool.
#
# Despite the class name, this is the shared pool for every runtime Zimmer
# authenticates (Claude Code and Codex today) — the `runtime` column
# discriminates rows. Each account has its own credentials (stored in
# oauth_config) and can be rotated in/out when usage quotas are hit. Only one
# account per runtime is active (is_current) at a time — all sessions on the
# worker for that runtime share it.
#
# Credential shape by runtime (stored in oauth_config):
#   claude_code — { "claude_json" => {...}, "credentials_json" => {...} }
#                 (the contents of ~/.claude.json and ~/.claude/.credentials.json)
#   codex       — OAuth: { "auth_json" => {...} } (the contents of ~/.codex/auth.json)
#                 API key: { "api_key" => "sk-..." }
#
# Runtime-specific constants (token endpoints, client IDs, credential file
# paths) live in the matching provider — ClaudeAuthProvider and
# CodexAuthProvider — the single source of truth for each runtime's auth
# lifecycle. The token-introspection and refresh methods below dispatch on
# `runtime` so the generic refresh dispatcher can stay runtime-agnostic.
#
# Accounts are managed via rake tasks (one namespace per runtime):
#   bin/rails 'claude_accounts:add[email@example.com,0]'
#   bin/rails 'codex_accounts:add[email@example.com,0]'
#   bin/rails claude_accounts:list  /  bin/rails codex_accounts:list
class ClaudeAccount < ApplicationRecord
  # Agent runtimes that can own an account in this pool.
  RUNTIMES = %w[claude_code codex].freeze

  # Transient network failures raised while talking to a runtime's token
  # endpoint. These are self-recovering: RefreshRuntimeAuthTokensJob retries
  # with exponential backoff and escalates to .error only after retries are
  # exhausted. The refresh methods therefore log these at .info — a single
  # isolated blip must not trip the production ERROR-logs alert.
  TRANSIENT_REFRESH_ERRORS = [
    Net::OpenTimeout,
    Net::ReadTimeout,
    Errno::ECONNRESET,
    Errno::ECONNREFUSED,
    Errno::ETIMEDOUT,
    Errno::EHOSTUNREACH,
    Errno::ENETUNREACH,
    SocketError,
    OpenSSL::SSL::SSLError
  ].freeze

  enum :status, { active: 0, quota_exceeded: 1, needs_reauth: 2 }

  has_many :quota_snapshots,
    class_name: "ClaudeAccountQuotaSnapshot",
    dependent: :destroy
  has_many :rotation_events_from,
    class_name: "AccountRotationEvent",
    foreign_key: :rotated_from_id,
    dependent: :nullify
  has_many :rotation_events_to,
    class_name: "AccountRotationEvent",
    foreign_key: :rotated_to_id,
    dependent: :destroy
  has_many :runtime_login_attempts, dependent: :destroy

  # Email uniqueness is scoped to runtime: the same person can hold one account
  # per runtime (e.g. a claude_code AND a codex account for tadas@tadasant.com).
  # Two accounts with the same email on the SAME runtime are still rejected.
  validates :email, presence: true, uniqueness: { scope: :runtime }
  validates :priority, numericality: { only_integer: true }
  validates :runtime, inclusion: { in: RUNTIMES }

  scope :available, -> { active.where.not(oauth_config: {}).order(:priority) }
  scope :for_runtime, ->(runtime) { where(runtime: runtime) }

  # Returns the DB-authoritative current account.
  #
  # The DB is the single source of truth for which account is active.
  # Filesystem reconciliation was removed because web and worker containers
  # have separate ~/.claude.json files (only ~/.claude/.credentials.json is
  # shared via bind mount). Filesystem-wins reconciliation caused switches
  # made from the web container to be silently reverted when the worker read
  # its own stale ~/.claude.json.
  #
  # The worker-side filesystem is kept in sync by
  # AccountRotationService#ensure_active_account!, which detects mismatches
  # and writes the DB-current account's config to disk before each session.
  #
  # Scoped to a runtime (defaults to Claude Code) because each runtime keeps
  # its own current account — only one row per runtime carries is_current.
  def self.current_account(runtime = ClaudeAuthProvider::RUNTIME)
    for_runtime(runtime).find_by(is_current: true)
  end

  # Reads ~/.claude.json and ~/.claude/.credentials.json and populates the
  # matching ClaudeAccount's oauth_config. Used when the CLI has been
  # manually logged in but the DB record is empty (the common "forgot to
  # run capture_tokens" case). If no account is marked current, also marks
  # the synced account as current so subsequent spawns use it.
  #
  # @return [ClaudeAccount, nil] the synced account, or nil if no matching
  #   account exists in the DB or the filesystem files are missing.
  def self.sync_from_filesystem!
    return nil unless File.exist?(ClaudeAuthProvider::CREDENTIALS_JSON_PATH)

    fs_email = filesystem_oauth_email
    if fs_email.blank?
      Rails.logger.info "[ClaudeAccount] sync_from_filesystem!: no oauthAccount email in filesystem"
      return nil
    end

    # Email is unique only per-runtime, so this Claude-Code filesystem-sync path
    # must scope to the Claude Code runtime — otherwise a same-email Codex row
    # could be matched and have Claude credentials grafted onto it.
    account = for_runtime(ClaudeAuthProvider::RUNTIME).find_by(email: fs_email)
    unless account
      Rails.logger.info "[ClaudeAccount] sync_from_filesystem!: no DB account for filesystem email #{fs_email}"
      return nil
    end

    oauth_config = {}
    oauth_config["claude_json"] = JSON.parse(File.read(ClaudeAuthProvider::CLAUDE_JSON_PATH)) if File.exist?(ClaudeAuthProvider::CLAUDE_JSON_PATH)
    credentials_json = JSON.parse(File.read(ClaudeAuthProvider::CREDENTIALS_JSON_PATH))
    oauth_config["credentials_json"] = credentials_json

    # Refuse to bootstrap a refresh-token-less credential set into the DB. The
    # Claude CLI sometimes rewrites .credentials.json without the claudeAiOauth
    # tokens; adopting that here would brick the account the moment its access
    # token expires (see complete_claude_oauth?). This guard mirrors the one in
    # sync_tokens_from_filesystem! so no entry point can poison the pool.
    unless complete_claude_oauth?(credentials_json)
      Rails.logger.warn "[ClaudeAccount] sync_from_filesystem!: filesystem credentials for #{fs_email} are incomplete (missing accessToken or refreshToken); refusing to bootstrap"
      return nil
    end

    account.update!(oauth_config: oauth_config, status: :active)

    # The credentials we just adopted are physically on disk and belong to
    # fs_email, so stamp the shared marker to match. Without this, the
    # marker-gated token-capture paths wouldn't recognize this account as the
    # on-disk owner until the next full write_config!.
    write_credentials_owner_marker!(fs_email)

    # If nothing is currently marked, adopt this account as current so
    # ensure_active_account! doesn't keep treating it as unavailable.
    if current_account.nil?
      account.mark_current!
      Rails.logger.info "[ClaudeAccount] sync_from_filesystem!: marked #{fs_email} as current (no prior current account)"
    end

    Rails.logger.info "[ClaudeAccount] sync_from_filesystem!: captured tokens for #{fs_email}"
    account
  rescue JSON::ParserError => e
    Rails.logger.warn "[ClaudeAccount] sync_from_filesystem! JSON parse error: #{e.message}"
    nil
  end

  # Returns the email address currently present in ~/.claude.json's
  # oauthAccount field, or nil if the file is missing/unparseable.
  def self.filesystem_oauth_email
    return nil unless File.exist?(ClaudeAuthProvider::CLAUDE_JSON_PATH)

    config = JSON.parse(File.read(ClaudeAuthProvider::CLAUDE_JSON_PATH))
    oauth_account = config["oauthAccount"]
    return nil if oauth_account.blank?
    oauth_account.is_a?(Hash) ? oauth_account["emailAddress"] : oauth_account
  rescue JSON::ParserError
    nil
  end

  def has_valid_config?
    oauth_config.present? && oauth_config.is_a?(Hash) && oauth_config.keys.any?
  end

  # True when a credentials_json blob carries both an accessToken and a
  # refreshToken under claudeAiOauth.
  #
  # This is the single completeness invariant for Claude credentials. Anthropic
  # rotates AND invalidates the refresh token on every successful refresh, so a
  # credentials set that has an accessToken but no refreshToken is a dead end:
  # once that access token expires, nothing can mint a new one and the account is
  # unrecoverable without a fresh interactive login. The Claude Code CLI is known
  # to occasionally rewrite ~/.claude/.credentials.json without the claudeAiOauth
  # fields while managing MCP OAuth state (see sync_tokens_from_filesystem!).
  #
  # Every path that persists Claude credentials — into the DB or onto the shared
  # filesystem — gates on this so an incomplete set can never enter the pool and
  # brick rotation. See https://docs.zimmer.tadasant.com/auth/harness/.
  def self.complete_claude_oauth?(credentials_json)
    oauth = credentials_json.is_a?(Hash) ? credentials_json["claudeAiOauth"] : nil
    oauth.is_a?(Hash) && oauth["accessToken"].present? && oauth["refreshToken"].present?
  end

  # The email Zimmer recorded as the owner of the SHARED ~/.claude/.credentials.json,
  # read from the sidecar owner marker, or nil if the marker is missing or
  # unparseable.
  #
  # This marker — not the per-container ~/.claude.json — is the authoritative
  # answer to "whose tokens are currently in the shared credentials file." Because
  # the marker lives in the same shared bind mount as the credentials it
  # describes, the web and worker containers always agree on it, whereas
  # ~/.claude.json is container-local and routinely disagrees across containers.
  # Trusting ~/.claude.json to describe the shared credentials is what let one
  # account's tokens be grafted onto another account's DB row. See
  # ClaudeAuthProvider.credentials_owner_path and
  # https://docs.zimmer.tadasant.com/auth/harness/.
  def self.credentials_owner_email
    path = ClaudeAuthProvider.credentials_owner_path
    return nil unless File.exist?(path)

    JSON.parse(File.read(path))["email"].presence
  rescue JSON::ParserError
    nil
  end

  # Record which account owns the shared credentials file. Written atomically
  # alongside every successful write to ~/.claude/.credentials.json so the marker
  # never describes credentials that aren't actually on disk.
  def self.write_credentials_owner_marker!(email)
    path = ClaudeAuthProvider.credentials_owner_path
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate("email" => email, "written_at" => Time.current.utc.iso8601))
  end

  def codex?
    runtime == CodexAuthProvider::RUNTIME
  end

  def latest_snapshot
    quota_snapshots.order(created_at: :desc).first
  end

  def mark_quota_exceeded!
    update!(
      status: :quota_exceeded,
      quota_hit_count: quota_hit_count + 1
    )
  end

  # Mark this account as the current one for its runtime. Scoped to the same
  # runtime so activating (e.g.) a Codex account doesn't clear the Claude
  # pool's current flag — each runtime keeps an independent current account.
  def mark_current!
    self.class.for_runtime(runtime).where.not(id: id).update_all(is_current: false)
    update!(is_current: true, last_rotated_to_at: Time.current)
  end

  # Returns the token expiration time derived from oauth_config, or nil when the
  # account never expires (API-key accounts) or has no token data.
  # @return [Time, nil]
  def token_expires_at
    codex? ? codex_token_expires_at : claude_token_expires_at
  end

  def token_expired?
    return codex_token_expired? if codex?

    expires = claude_token_expires_at
    expires.nil? || expires <= Time.current
  end

  def token_expiring_soon?(threshold = 15.minutes)
    return codex_token_expiring_soon?(threshold) if codex?

    expires = claude_token_expires_at
    return false if expires.nil?
    expires < threshold.from_now
  end

  # Returns true if the account has a refresh token that can be used.
  # API-key Codex accounts have nothing to refresh and return false.
  def can_refresh_token?
    if codex?
      codex_refresh_token.present?
    else
      oauth_config&.dig("credentials_json", "claudeAiOauth", "refreshToken").present?
    end
  end

  # Refreshes the access token using the runtime's OAuth refresh_token grant.
  # Updates oauth_config in the DB and writes to the runtime's credential file
  # if this is the current account.
  #
  # @return [true] if refresh succeeded (or there is nothing to refresh)
  # @return [false] if refresh failed
  # @param recovery_probe [Boolean] when true, this is a best-effort probe of an
  #   account already known to be in needs_reauth (see
  #   RuntimeAuthProvider#recover_needs_reauth). An expected probe failure is logged
  #   at .info rather than .error/.warn — the real failure already alerted when the
  #   account first transitioned to needs_reauth, and a known-dead token fails every
  #   cycle until a human re-authenticates.
  def refresh_token!(recovery_probe: false)
    return refresh_codex_token!(recovery_probe: recovery_probe) if codex?

    # The Claude CLI refreshes tokens independently during sessions, and Anthropic's
    # OAuth endpoint rotates refresh_token for security. When that happens, the CLI
    # writes the new pair to ~/.claude/.credentials.json but Zimmer's DB copy stays
    # stale — using it would fail with invalid_grant. Sync from filesystem first.
    # sync_tokens_from_filesystem! is a no-op when ~/.claude.json's identity does
    # not match this account or when ~/.claude.json is missing entirely.
    sync_tokens_from_filesystem!

    refresh_tok = oauth_config&.dig("credentials_json", "claudeAiOauth", "refreshToken")
    raise "Cannot refresh: missing refresh token for #{email}" unless refresh_tok.present?

    uri = URI(ClaudeAuthProvider::TOKEN_ENDPOINT)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 5
    http.read_timeout = 10
    request = Net::HTTP::Post.new(uri.path)
    request.set_form_data({
      grant_type: "refresh_token",
      refresh_token: refresh_tok,
      client_id: ClaudeAuthProvider::CLIENT_ID
    })
    response = http.request(request)

    if response.code.start_with?("2")
      token_data = JSON.parse(response.body)
      new_expires_at_ms = token_data["expires_in"] ? ((Time.current + token_data["expires_in"].to_i.seconds).to_f * 1000).to_i : nil

      updated_credentials = oauth_config.deep_dup
      claude_oauth = updated_credentials.dig("credentials_json", "claudeAiOauth") || {}
      claude_oauth["accessToken"] = token_data["access_token"]
      claude_oauth["refreshToken"] = token_data["refresh_token"] || refresh_tok
      claude_oauth["expiresAt"] = new_expires_at_ms if new_expires_at_ms
      updated_credentials["credentials_json"] ||= {}
      updated_credentials["credentials_json"]["claudeAiOauth"] = claude_oauth

      update!(oauth_config: updated_credentials)

      # Write to filesystem if this is the currently active account
      write_credentials_to_filesystem! if is_current?

      Rails.logger.info "[ClaudeAccount] Token refresh succeeded for #{email}"
      true
    elsif recovery_probe
      Rails.logger.info "[ClaudeAccount] Recovery probe for #{email} still failing (#{response.code}); awaiting re-auth"
      false
    elsif permanent_refresh_failure?(response)
      # A known-permanent failure (e.g. 400 invalid_grant, 401, 404): the account
      # is gracefully marked needs_reauth and rotated out of the active pool, so
      # this is expected and handled. Log at .warn — not .error — so it does not
      # page on a recoverable, non-alerting condition (the human re-auths to recover).
      Rails.logger.warn "[ClaudeAccount] Refresh token permanently invalid for #{email} (#{response.code}), marking needs_reauth: #{response.body}"
      update!(status: :needs_reauth)
      false
    else
      # An unexpected non-2xx response — neither a known permanent OAuth error nor
      # a retried transient exception — means the refresh path is genuinely broken.
      # Keep this at .error so a true persistent refresh outage still pages.
      Rails.logger.error "[ClaudeAccount] Token refresh failed for #{email}: #{response.code} - #{response.body}"
      false
    end
  rescue StandardError => e
    if recovery_probe
      Rails.logger.info "[ClaudeAccount] Recovery probe error for #{email}: #{e.message}; awaiting re-auth"
    elsif transient_refresh_error?(e)
      # The refresh job retries transient failures with backoff and escalates
      # to .error only once retries are exhausted, so log at .info here.
      Rails.logger.info "[ClaudeAccount] Token refresh transient error for #{email}: #{e.class} - #{e.message} (will retry)"
    else
      Rails.logger.error "[ClaudeAccount] Token refresh error for #{email}: #{e.message}"
    end
    false
  end

  # Reads the current shared filesystem credentials and updates this account's
  # oauth_config. Captures any tokens the Claude Code CLI rotated on its own
  # mid-session, so the DB copy doesn't go stale and 401 on the next refresh.
  #
  # Sync is gated by a strict identity match against the SHARED credentials-owner
  # marker (ClaudeAccount.credentials_owner_email): only the account the marker
  # names as the owner of ~/.claude/.credentials.json may adopt those tokens.
  # The marker lives in the shared bind mount alongside the credentials, so the
  # web and worker containers agree on it — unlike the per-container
  # ~/.claude.json, whose cross-container divergence previously let one account's
  # tokens be grafted onto another account's row.
  #
  # When no marker exists yet (the brief window after a deploy, before Zimmer has
  # written credentials once) we fall back to the legacy ~/.claude.json identity
  # check so token capture keeps working during the transition. The completeness
  # guard below runs in BOTH cases, so a refresh-token-less set can never be
  # adopted regardless of which gate authorized the identity.
  #
  # Rejects filesystem credentials missing accessToken or refreshToken: the
  # Claude CLI rewrites this file to manage MCP OAuth state, and on rare occasions
  # has clobbered the claudeAiOauth fields. Without this guard the sync would
  # propagate that corruption into the DB and brick the entire account pool.
  def sync_tokens_from_filesystem!
    return unless File.exist?(ClaudeAuthProvider::CREDENTIALS_JSON_PATH)
    return unless filesystem_credentials_owned_by_self?

    fs_credentials = JSON.parse(File.read(ClaudeAuthProvider::CREDENTIALS_JSON_PATH))
    unless self.class.complete_claude_oauth?(fs_credentials)
      Rails.logger.warn "[ClaudeAccount] Skipping filesystem sync for #{email}: filesystem credentials are corrupted (missing accessToken or refreshToken)"
      return
    end

    updated = oauth_config.deep_dup
    updated["credentials_json"] = fs_credentials
    update!(oauth_config: updated)
  rescue JSON::ParserError => e
    Rails.logger.warn "[ClaudeAccount] Failed to parse credentials file: #{e.message}"
  end

  # Writes the credentials portion of oauth_config to the shared filesystem,
  # then stamps the credentials-owner marker so every later reader knows whose
  # tokens are on disk.
  #
  # Refuses to write an incomplete credential set: clobbering the shared file with
  # a refresh-token-less blob would erase the refresh token from disk and, on the
  # next sync, from the DB — exactly the failure that bricked the pool.
  def write_credentials_to_filesystem!
    credentials_json = oauth_config&.dig("credentials_json")
    return unless credentials_json.present?

    unless self.class.complete_claude_oauth?(credentials_json)
      Rails.logger.warn "[ClaudeAccount] Refusing to write incomplete credentials to filesystem for #{email} (missing accessToken or refreshToken)"
      return
    end

    credentials_dir = File.dirname(ClaudeAuthProvider::CREDENTIALS_JSON_PATH)
    FileUtils.mkdir_p(credentials_dir)
    File.write(ClaudeAuthProvider::CREDENTIALS_JSON_PATH, JSON.pretty_generate(credentials_json))
    self.class.write_credentials_owner_marker!(email)
  end

  # --- Codex identity accessors (used by CodexAuthProvider for fs reconciliation) ---

  # The ChatGPT account_id embedded in this Codex account's OAuth tokens, used to
  # match the filesystem identity. nil for API-key accounts.
  def codex_account_id
    codex_tokens&.dig("account_id")
  end

  # The OPENAI_API_KEY for an API-key Codex account, or nil for OAuth accounts.
  def codex_api_key
    oauth_config&.dig("api_key").presence || codex_auth_json&.dig("OPENAI_API_KEY").presence
  end

  # True when this Codex account authenticates with a static API key (nothing to
  # refresh, never expires) rather than rotating ChatGPT OAuth tokens.
  def codex_api_key_account?
    codex_api_key.present? && codex_refresh_token.blank?
  end

  # Reads ~/.codex/auth.json and, when its ChatGPT account_id matches this
  # account, captures the tokens (and last_refresh) the Codex CLI rotated on
  # disk back into oauth_config. The identity gate mirrors Claude's
  # sync_tokens_from_filesystem!: we only adopt filesystem tokens we can prove
  # belong to this account, so a different active account's credentials are
  # never written onto this row.
  def sync_codex_tokens_from_filesystem!
    return unless codex?
    return unless File.exist?(CodexAuthProvider::AUTH_JSON_PATH)

    fs = JSON.parse(File.read(CodexAuthProvider::AUTH_JSON_PATH))
    fs_tokens = fs["tokens"]
    unless fs_tokens.is_a?(Hash) && fs_tokens["account_id"].present? && fs_tokens["account_id"] == codex_account_id
      Rails.logger.info "[ClaudeAccount] Skipping codex filesystem sync for #{email}: filesystem identity is #{fs_tokens.is_a?(Hash) ? fs_tokens["account_id"].inspect : "absent"}"
      return
    end

    if fs_tokens["access_token"].blank? || fs_tokens["refresh_token"].blank?
      Rails.logger.warn "[ClaudeAccount] Skipping codex filesystem sync for #{email}: filesystem tokens are incomplete (missing access_token or refresh_token)"
      return
    end

    updated = oauth_config.deep_dup
    updated["auth_json"] = fs
    update!(oauth_config: updated)
  rescue JSON::ParserError => e
    Rails.logger.warn "[ClaudeAccount] Failed to parse codex auth.json: #{e.message}"
  end

  # Writes this Codex account's credentials to ~/.codex/auth.json so the next
  # CLI spawn authenticates as it. OAuth accounts write their stored auth.json
  # verbatim (preserving fields Zimmer doesn't model); API-key accounts write a
  # minimal { "OPENAI_API_KEY" => key } envelope.
  def write_codex_auth_to_filesystem!
    auth_json = codex_auth_json.presence || ({ "OPENAI_API_KEY" => codex_api_key } if codex_api_key.present?)
    return unless auth_json.present?

    FileUtils.mkdir_p(CodexAuthProvider::CODEX_HOME)
    File.write(CodexAuthProvider::AUTH_JSON_PATH, JSON.pretty_generate(auth_json))
  end

  private

  # True when an exception raised during token refresh is a transient network
  # failure (see TRANSIENT_REFRESH_ERRORS). Such failures are retried by the
  # refresh job, so they are logged at .info rather than tripping the ERROR alert.
  def transient_refresh_error?(error)
    TRANSIENT_REFRESH_ERRORS.any? { |klass| error.is_a?(klass) }
  end

  # True when the shared ~/.claude/.credentials.json belongs to this account,
  # per the shared credentials-owner marker.
  #
  # The marker is the only authority here — we deliberately do NOT fall back to
  # the per-container ~/.claude.json, because that file is the exact source of the
  # cross-container ambiguity this system exists to avoid: on the wrong container
  # it would confidently claim a different account owns the shared credentials.
  # When no marker exists yet (the brief post-deploy window before Zimmer's first
  # credential write) we refuse to sync — the safe default — and Zimmer converges the
  # marker into existence via ensure_active_account! and every write_config!.
  def filesystem_credentials_owned_by_self?
    owner = self.class.credentials_owner_email
    return true if owner.present? && owner == email

    Rails.logger.info "[ClaudeAccount] Skipping filesystem sync for #{email}: shared credentials owner is #{owner.inspect}"
    false
  end

  # Extracts the email from an oauthAccount value, which can be a plain string
  # (legacy CLI format) or a Hash with "emailAddress" (current CLI format).
  def extract_oauth_email(oauth_account)
    return nil if oauth_account.blank?
    oauth_account.is_a?(Hash) ? oauth_account["emailAddress"] : oauth_account
  end

  # Standard OAuth error codes that indicate the refresh token is permanently invalid
  PERMANENT_OAUTH_ERRORS = %w[invalid_grant invalid_client unauthorized_client].freeze

  # Anthropic error types that indicate the refresh token is permanently invalid.
  # Anthropic uses a nested format: {"error": {"type": "...", "message": "..."}}
  PERMANENT_ANTHROPIC_ERROR_TYPES = %w[invalid_request_error authentication_error].freeze

  def permanent_refresh_failure?(response)
    return true if %w[401 404].include?(response.code)
    return false unless response.code == "400"

    begin
      body = JSON.parse(response.body)
    rescue JSON::ParserError
      return false
    end

    error_field = body["error"]

    # Standard OAuth format: {"error": "invalid_grant"}
    if error_field.is_a?(String)
      return PERMANENT_OAUTH_ERRORS.include?(error_field)
    end

    # Anthropic format: {"error": {"type": "invalid_request_error", "message": "..."}}
    if error_field.is_a?(Hash)
      return PERMANENT_ANTHROPIC_ERROR_TYPES.include?(error_field["type"])
    end

    false
  end

  # --- Claude token helpers ---

  # The Claude token expiration parsed from oauth_config. The expiresAt field is
  # stored in milliseconds since epoch.
  # @return [Time, nil]
  def claude_token_expires_at
    ms = oauth_config&.dig("credentials_json", "claudeAiOauth", "expiresAt")
    ms.present? ? Time.at(ms.to_f / 1000.0) : nil
  end

  # --- Codex token helpers ---

  def codex_auth_json
    oauth_config&.dig("auth_json")
  end

  def codex_tokens
    codex_auth_json&.dig("tokens")
  end

  def codex_refresh_token
    codex_tokens&.dig("refresh_token")
  end

  # When the Codex CLI last refreshed the tokens on disk, parsed from auth.json's
  # last_refresh (ISO8601). Drives the TTL-based expiry below.
  # @return [Time, nil]
  def codex_last_refresh
    raw = codex_auth_json&.dig("last_refresh")
    raw.present? ? Time.zone.parse(raw.to_s) : nil
  rescue ArgumentError, TypeError
    nil
  end

  # Codex auth.json carries no explicit access-token expiry, and the CLI
  # refreshes the active account's tokens in place at runtime. Zimmer refreshes pool
  # accounts on a soft TTL (CodexAuthProvider::TOKEN_TTL) measured from
  # last_refresh, which keeps refresh tokens warm and fires roughly once per day.
  # API-key accounts never expire.
  # @return [Time, nil]
  def codex_token_expires_at
    return nil if codex_api_key_account?

    last = codex_last_refresh
    last ? last + CodexAuthProvider::TOKEN_TTL : nil
  end

  def codex_token_expired?
    return false if codex_api_key_account?

    expires = codex_token_expires_at
    # No last_refresh recorded → treat as stale so the next sweep refreshes it.
    expires.nil? || expires <= Time.current
  end

  def codex_token_expiring_soon?(threshold)
    return false if codex_api_key_account?

    expires = codex_token_expires_at
    # No last_refresh recorded → refresh on the next sweep.
    return true if expires.nil?
    expires < threshold.from_now
  end

  # Refreshes Codex ChatGPT OAuth tokens via OpenAI's token endpoint.
  # API-key accounts have nothing to refresh and succeed as a no-op.
  #
  # @return [true] if refresh succeeded (or nothing to refresh)
  # @return [false] if refresh failed
  # @param recovery_probe [Boolean] see #refresh_token! — downgrades the expected
  #   failure log to .info when probing a known needs_reauth account.
  def refresh_codex_token!(recovery_probe: false)
    # API-key accounts authenticate statically — nothing to rotate.
    return true if codex_api_key_account?

    # The Codex CLI refreshes the active account's tokens in place during
    # sessions and OpenAI rotates the refresh_token on each use. When that
    # happens the CLI writes the new pair to ~/.codex/auth.json while Zimmer's DB
    # copy goes stale — replaying it yields refresh_token_reused. Sync the
    # filesystem tokens (identity-gated, no-op when they aren't ours) first.
    sync_codex_tokens_from_filesystem!

    refresh_tok = codex_refresh_token
    raise "Cannot refresh: missing refresh token for #{email}" unless refresh_tok.present?

    uri = URI(CodexAuthProvider::TOKEN_ENDPOINT)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 5
    http.read_timeout = 10
    request = Net::HTTP::Post.new(uri.path)
    request["Content-Type"] = "application/json"
    request.body = JSON.generate({
      client_id: CodexAuthProvider::CLIENT_ID,
      grant_type: "refresh_token",
      refresh_token: refresh_tok
    })
    response = http.request(request)

    if response.code.start_with?("2")
      token_data = JSON.parse(response.body)

      updated = oauth_config.deep_dup
      auth_json = updated["auth_json"] ||= {}
      tokens = auth_json["tokens"] ||= {}
      # Each field is rotated only when the response includes it, matching the
      # Codex CLI's persist_tokens behavior; account_id and other fields persist.
      tokens["id_token"] = token_data["id_token"] if token_data["id_token"].present?
      tokens["access_token"] = token_data["access_token"] if token_data["access_token"].present?
      tokens["refresh_token"] = token_data["refresh_token"] if token_data["refresh_token"].present?
      auth_json["last_refresh"] = Time.current.utc.iso8601

      update!(oauth_config: updated)

      write_codex_auth_to_filesystem! if is_current?

      Rails.logger.info "[ClaudeAccount] Codex token refresh succeeded for #{email}"
      true
    elsif recovery_probe
      Rails.logger.info "[ClaudeAccount] Codex recovery probe for #{email} still failing (#{response.code}); awaiting re-auth"
      false
    elsif codex_permanent_refresh_failure?(response)
      # A known-permanent failure (e.g. 401, refresh_token_expired/reused/invalidated):
      # the account is gracefully marked needs_reauth and rotated out of the active
      # pool, so this is expected and handled. Log at .warn — not .error — so it does
      # not page on a recoverable, non-alerting condition (the human re-auths to recover).
      Rails.logger.warn "[ClaudeAccount] Codex refresh token permanently invalid for #{email} (#{response.code}), marking needs_reauth: #{response.body}"
      update!(status: :needs_reauth)
      false
    else
      # An unexpected non-2xx response — neither a known permanent OAuth error nor
      # a retried transient exception — means the refresh path is genuinely broken.
      # Keep this at .error so a true persistent refresh outage still pages.
      Rails.logger.error "[ClaudeAccount] Codex token refresh failed for #{email}: #{response.code} - #{response.body}"
      false
    end
  rescue StandardError => e
    if recovery_probe
      Rails.logger.info "[ClaudeAccount] Codex recovery probe error for #{email}: #{e.message}; awaiting re-auth"
    elsif transient_refresh_error?(e)
      # The refresh job retries transient failures with backoff and escalates
      # to .error only once retries are exhausted, so log at .info here.
      Rails.logger.info "[ClaudeAccount] Codex token refresh transient error for #{email}: #{e.class} - #{e.message} (will retry)"
    else
      Rails.logger.error "[ClaudeAccount] Codex token refresh error for #{email}: #{e.message}"
    end
    false
  end

  # OpenAI error codes that indicate the Codex refresh token is permanently
  # invalid (mirrors the Codex CLI's classify_refresh_token_failure).
  PERMANENT_CODEX_ERROR_CODES = %w[refresh_token_expired refresh_token_reused refresh_token_invalidated].freeze

  def codex_permanent_refresh_failure?(response)
    return true if response.code == "401"

    begin
      body = JSON.parse(response.body)
    rescue JSON::ParserError
      return false
    end
    return false unless body.is_a?(Hash)

    # Error code can appear as { "error": { "code": "..." } }, { "error": "..." },
    # or a top-level { "code": "..." }.
    error_field = body["error"]
    code =
      if error_field.is_a?(Hash)
        error_field["code"]
      elsif error_field.is_a?(String)
        error_field
      else
        body["code"]
      end

    PERMANENT_CODEX_ERROR_CODES.include?(code)
  end
end
