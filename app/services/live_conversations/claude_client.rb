# frozen_string_literal: true

module LiveConversations
  # Live Mode's Claude: the Messages API through the official `anthropic` gem,
  # for the experimental voice engines' reasoning (ClaudeDelegate).
  #
  # It runs on Zimmer's own Claude credential — the pooled Claude Code
  # subscription account that agent sessions run on (ClaudeAccount
  # `current_account`, the token a session is handed as CLAUDE_CODE_OAUTH_TOKEN)
  # — and nobody supplies an Anthropic key for it. The token goes as a Bearer
  # token with the OAuth beta header, exactly as QuotaCheckService sends the
  # same token to the same endpoint. It is read afresh for every client, so an
  # account rotation or a token refresh reaches Live Mode on the next
  # delegation.
  #
  # That makes Claude's use here subscription-billed and quota-bearing: it draws
  # on the same 5-hour and weekly windows as the agent fleet. With no usable
  # account, the engines that need Claude are unavailable and calls fall back to
  # OpenAI Realtime (VoiceEngine). `LIVE_ANTHROPIC_BASE_URL` points the client
  # elsewhere — a proxy, or a local stand-in when proving the flow end to end;
  # the fleet's subscription token is sent wherever it points.
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

    class Error < StandardError; end
    class NotConfiguredError < Error; end

    # The current account's token and nil, or nil and why Live Mode cannot
    # reach Claude now. Read once, so the two cannot describe different
    # accounts. The test is the one sessions spawn on
    # (ClaudeAccount#usable_as_current?): an account out of quota, waiting to be
    # re-authenticated, or refused by Anthropic is unavailable, and the engine
    # falls back rather than failing every delegation mid-call.
    def self.credential
      account = ClaudeAccount.current_account(ClaudeAuthProvider::RUNTIME)
      return [ account.claude_access_token, nil ] if account&.usable_as_current?

      [ nil, refusal_for(account) ]
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("[claude] could not read the current Claude Code account: #{e.class}")
      [ nil, "Zimmer's Claude Code accounts could not be read" ]
    end

    def self.refusal_for(account)
      if account.nil? then "Zimmer has no current Claude Code account"
      elsif account.claude_access_token.blank? then "Zimmer's current Claude Code account has no credentials"
      elsif account.credential_rejected? || account.needs_reauth? then "Zimmer's current Claude Code account needs re-authenticating (/inference)"
      elsif account.quota_exceeded? then "Zimmer's current Claude Code account is out of quota"
      else "Zimmer's current Claude Code account cannot serve right now"
      end
    end

    def self.access_token = credential.first

    def self.unavailable_reason = credential.last

    def self.configured? = unavailable_reason.nil?

    def self.base_url = ENV.fetch("LIVE_ANTHROPIC_BASE_URL", "").presence || DEFAULT_BASE_URL

    def initialize(credential: self.class.credential, base_url: self.class.base_url)
      access_token, reason = credential
      raise NotConfiguredError, (reason || "Zimmer has no Claude credential") if access_token.blank?

      # An explicit `auth_token:` is what keeps the gem from reading
      # ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN or a profile from the environment:
      # given one, it looks for no other credential.
      @client = Anthropic::Client.new(auth_token: access_token, base_url: base_url, timeout: TIMEOUT_SECONDS, max_retries: MAX_RETRIES)
    end

    # @return [Hash] the message, string keys
    def create_message(**params)
      # Per request: the gem applies a client-level timeout only when it is
      # its own default, and otherwise falls back to ten minutes.
      options = { timeout: TIMEOUT_SECONDS, extra_headers: { "anthropic-beta" => OAUTH_BETA } }
      JSON.parse(@client.messages.create(**params, request_options: options).to_json)
    rescue Anthropic::Errors::APIError => e
      raise Error, "Claude: #{e.message.to_s.truncate(300)}"
    end
  end
end
