# frozen_string_literal: true

module LiveConversations
  # Live Mode's Claude: the Messages API through the official `anthropic` gem,
  # for the experimental voice engines' reasoning (ClaudeDelegate).
  #
  # Two credentials, in this order:
  #
  # 1. `LIVE_ANTHROPIC_API_KEY`, an Anthropic Console API key, resolved through
  #    SecretProviders (Parameter Store, Rails credentials, ENV) like
  #    LIVE_OPENAI_API_KEY. Sent as `x-api-key`; every Claude model answers on
  #    it, and its use is metered. Deliberately not `ANTHROPIC_API_KEY`:
  #    store-resolved variables can reach session environments, and Claude Code
  #    reads that name on its own — a key set for Live must not change how the
  #    agent fleet authenticates or bills.
  # 2. Otherwise, Zimmer's own Claude Code subscription account — the pooled
  #    account agent sessions run on (ClaudeAccount `current_account`, the token
  #    a session is handed as CLAUDE_CODE_OAUTH_TOKEN) — as a Bearer token with
  #    the OAuth beta header, exactly as QuotaCheckService sends it. Anthropic
  #    restricts that token to Claude Code: outside it, Opus and Sonnet are
  #    refused (a 429 `rate_limit_error` whose message is just "Error", while
  #    the fleet on the same account is fine), so this path is a fallback.
  #    {Error#subscription_refused?} names that refusal for ClaudeDelegate.
  #
  # Both are read afresh for every client, so a key set in the store, an
  # account rotation or a token refresh reaches Live Mode on the next
  # delegation. With neither usable, the engines that need Claude are
  # unavailable and calls fall back to OpenAI Realtime (VoiceEngine).
  # `LIVE_ANTHROPIC_BASE_URL` points the client elsewhere — a proxy, or a local
  # stand-in when proving the flow end to end; the credential is sent wherever
  # it points.
  #
  # Answers are plain string-keyed hashes, the wire shape, so nothing past this
  # class depends on the gem's model classes.
  class ClaudeClient
    DEFAULT_BASE_URL = "https://api.anthropic.com"
    # A subscription OAuth token is accepted on the Messages API only with this
    # opt-in (QuotaCheckService::OAUTH_BETA, the same value).
    OAUTH_BETA = QuotaCheckService::OAUTH_BETA
    # A delegation is waited on by a voice call; a slow one is worth less than
    # a quick "I could not get that" the person hears.
    TIMEOUT_SECONDS = 45
    MAX_RETRIES = 1

    API_KEY_VARIABLE = "LIVE_ANTHROPIC_API_KEY"

    # Which credential a client runs on: `:api_key` (metered) or
    # `:subscription` (Zimmer's Claude Code account).
    Credential = Data.define(:kind, :secret) do
      def subscription? = kind == :subscription
      def billing_basis = subscription? ? "subscription" : "metered"
      # Never the secret, however it is printed.
      def inspect = "#<#{self.class.name} kind=#{kind}>"
      alias_method :to_s, :inspect
      def pretty_print(printer) = printer.text(inspect)
      def to_h = { kind: kind }
    end

    # `status` is the HTTP status (nil for a connection failure or timeout);
    # `api_message` Anthropic's own error message; `credential_kind` what the
    # request was sent on.
    class Error < StandardError
      attr_reader :status, :api_message, :credential_kind

      def initialize(message = nil, status: nil, api_message: nil, credential_kind: nil)
        super(message)
        @status = status
        @api_message = api_message
        @credential_kind = credential_kind
      end

      # Anthropic turned the request down because of the credential it came
      # on, rather than failing to answer it.
      def credential_refused?
        return false if status.nil?
        return true if [ 401, 403 ].include?(status)
        return true if status == 400 && api_message.to_s.match?(/only authorized for use with claude code/i)

        subscription_refused?
      end

      # The subscription token's refusal outside Claude Code: a 429 whose
      # message is bare — a real rate limit says what it limited.
      def subscription_refused?
        credential_kind == :subscription && status == 429 && api_message.to_s.strip.in?([ "", "Error" ])
      end
    end

    class NotConfiguredError < Error; end

    # A Credential and nil, or nil and why Live Mode cannot reach Claude now.
    # Read once, so the two cannot describe different credentials. The API key
    # wins when it resolves. Otherwise the test is the one sessions spawn on
    # (ClaudeAccount#usable_as_current?): an account out of quota, waiting to be
    # re-authenticated, or refused by Anthropic is unavailable, and the engine
    # falls back rather than failing every delegation mid-call.
    def self.credential(chain: SecretProviders.chain)
      key = api_key(chain: chain)
      return [ Credential.new(kind: :api_key, secret: key), nil ] if key

      account = ClaudeAccount.current_account(ClaudeAuthProvider::RUNTIME)
      return [ Credential.new(kind: :subscription, secret: account.claude_access_token), nil ] if account&.usable_as_current?

      [ nil, refusal_for(account) ]
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("[claude] could not read the current Claude Code account: #{e.class}")
      [ nil, "Zimmer's Claude Code accounts could not be read" ]
    end

    def self.api_key(chain: SecretProviders.chain)
      chain.get(API_KEY_VARIABLE).presence
    rescue StandardError => e
      Rails.logger.warn("[claude] could not resolve #{API_KEY_VARIABLE}: #{e.class}")
      nil
    end

    def self.refusal_for(account)
      if account.nil? then "Zimmer has no current Claude Code account"
      elsif account.claude_access_token.blank? then "Zimmer's current Claude Code account has no credentials"
      elsif account.credential_rejected? || account.needs_reauth? then "Zimmer's current Claude Code account needs re-authenticating (/inference)"
      elsif account.quota_exceeded? then "Zimmer's current Claude Code account is out of quota"
      else "Zimmer's current Claude Code account cannot serve right now"
      end
    end

    def self.access_token = credential.first&.secret

    def self.unavailable_reason = credential.last

    def self.configured? = unavailable_reason.nil?

    def self.base_url = ENV.fetch("LIVE_ANTHROPIC_BASE_URL", "").presence || DEFAULT_BASE_URL

    attr_reader :credential

    def initialize(credential: self.class.credential, base_url: self.class.base_url)
      @credential, reason = credential
      raise NotConfiguredError, (reason || "Zimmer has no Claude credential") if @credential&.secret.blank?

      # An explicit `api_key:` or `auth_token:` is what keeps the gem from
      # reading ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN or a profile from the
      # environment: given one, it looks for no other credential.
      auth = @credential.subscription? ? { auth_token: @credential.secret } : { api_key: @credential.secret }
      @client = Anthropic::Client.new(**auth, base_url: base_url, timeout: TIMEOUT_SECONDS, max_retries: MAX_RETRIES)
    end

    # @return [Hash] the message, string keys
    def create_message(**params)
      # Per request: the gem applies a client-level timeout only when it is
      # its own default, and otherwise falls back to ten minutes.
      options = { timeout: TIMEOUT_SECONDS }
      options[:extra_headers] = { "anthropic-beta" => OAUTH_BETA } if @credential.subscription?
      JSON.parse(@client.messages.create(**params, request_options: options).to_json)
    rescue Anthropic::Errors::APIError => e
      raise Error.new("Claude: #{e.message.to_s.truncate(300)}", status: e.status, api_message: api_message(e),
                      credential_kind: @credential.kind)
    end

    private

    def api_message(error)
      body = error.body
      return unless body.is_a?(Hash)

      (body.dig(:error, :message) || body.dig("error", "message")).to_s.truncate(300)
    end
  end
end
