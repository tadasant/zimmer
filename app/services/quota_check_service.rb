# frozen_string_literal: true

class QuotaCheckService
  CREDENTIALS_PATH = File.join(Dir.home, ".claude", ".credentials.json")
  DEFAULT_BASE_URL = "https://api.anthropic.com"
  MESSAGES_PATH = "/v1/messages"
  PROFILE_PATH = "/api/oauth/profile"
  API_VERSION = "2023-06-01"
  # OAuth access tokens (sk-ant-oat01-*) are sent as a Bearer token together with
  # this beta opt-in header on every Anthropic request. Anthropic rejects OAuth
  # tokens supplied via the x-api-key header with HTTP 401 "invalid x-api-key".
  OAUTH_BETA = "oauth-2025-04-20"
  PROBE_MODEL = "claude-haiku-4-5-20251001"
  REQUEST_TIMEOUT = 10

  Result = Struct.new(
    :success, :error_message, :unreachable, :subscription_type, :rate_limit_tier, :email,
    :utilization_5h, :utilization_7d, :status_5h, :status_7d,
    :reset_5h, :reset_7d, :overage_status, :overage_disabled_reason,
    keyword_init: true
  ) do
    def success? = success

    # True when the probe never got an answer from Anthropic — a timeout, a DNS
    # or connection failure, or a 5xx. Such a failure is evidence about the
    # network, not about the token, so callers deciding whether a credential is
    # dead must not read it as a refusal.
    def unreachable? = !!unreachable
  end

  def self.check
    new.check
  end

  def self.check_with_token(token)
    new.check_with_token(token)
  end

  # True when Anthropic answered a probe of this access token and refused it.
  #
  # This is the pool's non-consuming validity test. Unlike ClaudeAccount#refresh_token!,
  # which spends a SINGLE-USE refresh token to find out whether credentials work,
  # this reads the rate-limit headers off a 1-token message — so it can be run
  # over every candidate in the pool without burning anything (#242).
  #
  # It answers false when it cannot tell: a blank result from an unreachable API
  # says nothing about the credential, and condemning the whole pool on an
  # Anthropic blip would park every session at once. A blank token, on the other
  # hand, is a refusal — there is nothing to present.
  #
  # @param token [String, nil] an OAuth access token (sk-ant-oat01-*)
  # @return [Boolean] true only when the token was presented and rejected
  def self.token_rejected?(token)
    return true if token.blank?

    result = check_with_token(token)
    return false if result.success?

    !result.unreachable?
  rescue StandardError => e
    Rails.logger.warn "[QuotaCheckService] Token probe raised, treating as inconclusive: #{e.message}"
    false
  end

  def check
    credentials = read_credentials
    return credentials if credentials.is_a?(Result)

    token = credentials.dig("claudeAiOauth", "accessToken")
    return error_result("No access token found in credentials") unless token.present?

    check_with_token(token)
  end

  # Check quota using a provided OAuth access token directly,
  # bypassing the filesystem credential file.
  def check_with_token(token)
    return error_result("Token is blank") unless token.present?

    account_info = fetch_profile(token)
    fetch_quota(token, account_info)
  end

  private

  def read_credentials
    unless File.exist?(CREDENTIALS_PATH)
      return error_result("No credentials file found at #{CREDENTIALS_PATH}")
    end

    data = JSON.parse(File.read(CREDENTIALS_PATH))
    unless data.key?("claudeAiOauth")
      return error_result("No Claude AI OAuth credentials in #{CREDENTIALS_PATH}")
    end
    data
  rescue JSON::ParserError => e
    error_result("Failed to parse credentials: #{e.message}")
  end

  def base_url
    (ENV["ANTHROPIC_BASE_URL"] || DEFAULT_BASE_URL).chomp("/")
  end

  def fetch_profile(token)
    uri = URI("#{base_url}#{PROFILE_PATH}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = REQUEST_TIMEOUT
    http.read_timeout = REQUEST_TIMEOUT

    request = Net::HTTP::Get.new(uri.request_uri)
    request["authorization"] = "Bearer #{token}"
    request["anthropic-beta"] = OAUTH_BETA
    request["anthropic-version"] = API_VERSION

    response = http.request(request)
    data = JSON.parse(response.body)

    {
      email: data.dig("account", "email"),
      subscription_type: data.dig("organization", "organization_type"),
      rate_limit_tier: data.dig("organization", "rate_limit_tier")
    }
  rescue StandardError
    { email: nil, subscription_type: nil, rate_limit_tier: nil }
  end

  def fetch_quota(token, account_info)
    uri = URI("#{base_url}#{MESSAGES_PATH}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = REQUEST_TIMEOUT
    http.read_timeout = REQUEST_TIMEOUT

    request = Net::HTTP::Post.new(uri.request_uri)
    request["authorization"] = "Bearer #{token}"
    request["anthropic-beta"] = OAUTH_BETA
    request["anthropic-version"] = API_VERSION
    request["content-type"] = "application/json"
    request.body = {
      model: PROBE_MODEL, max_tokens: 1,
      messages: [ { role: "user", content: "x" } ]
    }.to_json

    response = http.request(request)
    parse_headers(response, account_info)
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    error_result("API request timed out: #{e.message}", unreachable: true)
  rescue SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH => e
    error_result("Cannot reach Anthropic API: #{e.message}", unreachable: true)
  rescue StandardError => e
    # Anything raised here happened on the way to Anthropic — a refusal arrives as
    # a response, not an exception — so it is a transport failure, not a verdict
    # on the token.
    error_result("API request failed: #{e.message}", unreachable: true)
  end

  def parse_headers(response, account_info)
    utilization_5h = response["anthropic-ratelimit-unified-5h-utilization"]
    utilization_7d = response["anthropic-ratelimit-unified-7d-utilization"]

    if utilization_5h.nil? && utilization_7d.nil?
      # A 5xx is Anthropic failing, not the token failing. Flagging it unreachable
      # keeps a provider outage from reading as "every credential in the pool is
      # dead" to the callers that probe before activating an account.
      return error_result(
        "No rate-limit headers in response (HTTP #{response.code}). Token may be expired or invalid.",
        unreachable: response.code.to_i >= 500
      )
    end

    reset_5h_epoch = response["anthropic-ratelimit-unified-5h-reset"]
    reset_7d_epoch = response["anthropic-ratelimit-unified-7d-reset"]

    Result.new(
      success: true,
      subscription_type: account_info[:subscription_type],
      rate_limit_tier: account_info[:rate_limit_tier],
      email: account_info[:email],
      utilization_5h: utilization_5h&.to_f,
      utilization_7d: utilization_7d&.to_f,
      status_5h: response["anthropic-ratelimit-unified-5h-status"],
      status_7d: response["anthropic-ratelimit-unified-7d-status"],
      reset_5h: reset_5h_epoch ? Time.at(reset_5h_epoch.to_i) : nil,
      reset_7d: reset_7d_epoch ? Time.at(reset_7d_epoch.to_i) : nil,
      overage_status: response["anthropic-ratelimit-unified-overage-status"],
      overage_disabled_reason: response["anthropic-ratelimit-unified-overage-disabled-reason"]
    )
  end

  def error_result(message, unreachable: false)
    Result.new(success: false, error_message: message, unreachable: unreachable)
  end
end
