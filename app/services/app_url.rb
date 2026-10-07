# frozen_string_literal: true

# Single source of truth for this Zimmer instance's externally-reachable base URL.
#
# Every absolute link Zimmer emits into an outbound channel — the session URL in
# the orchestrator system prompt, the "View trigger in Zimmer" links in self-heal
# alerts, links surfaced by MCP tools — is built on top of this. It is read per
# environment from a `ZIMMER_*_BASE_URL` secret that the deploy provisions
# (`config/deploy.production.yml` / `config/deploy.staging.yml`); a self-hosted
# instance MUST set it, since the fallback is a placeholder host that produces
# broken links. The value is intentionally not baked into the image.
#
# `SelfSessionInjector` (the MCP endpoint it points sessions at) and
# `OrchestratorSystemPromptBuilder` (the session URL in the prompt) both read the
# host here, so the two cannot resolve it differently.
module AppUrl
  module_function

  # Placeholder hosts used only when the deploy has not set the base-URL secret.
  # They are non-functional on purpose: a self-hosted instance must override them
  # via `ZIMMER_PROD_BASE_URL` / `ZIMMER_STAGING_BASE_URL` (see configuration docs).
  PLACEHOLDER_PROD_BASE_URL = "https://zimmer.example.com"
  PLACEHOLDER_STAGING_BASE_URL = "https://staging.zimmer.example.com"

  # The variable each environment reads its base URL from. `AllowedHosts` reads
  # the same names from the process environment at boot. Loaded before Zeitwerk
  # (see AllowedHosts), so nothing here may reference an app constant at load time.
  BASE_URL_KEYS = { "production" => "ZIMMER_PROD_BASE_URL", "staging" => "ZIMMER_STAGING_BASE_URL" }.freeze
  LOCAL_BASE_URL_KEY = "ZIMMER_LOCAL_BASE_URL"

  # The externally-reachable base URL of this Zimmer instance, no trailing slash.
  #
  # @param env [String] Rails environment name (injectable for testing)
  # @param secrets_interpolator [SecretsInterpolator] resolves the env-var / secret lookup
  # @return [String] e.g. "https://zimmer.your-domain.com" when configured
  def base_url(env: Rails.env, secrets_interpolator: SecretsInterpolator.new)
    resolved = secrets_interpolator.get_env_value(base_url_key(env)) || fallback_base_url(env)

    resolved.to_s.chomp("/")
  end

  # @return [String] the variable `env` reads its base URL from
  def base_url_key(env = Rails.env)
    BASE_URL_KEYS.fetch(env.to_s, LOCAL_BASE_URL_KEY)
  end

  # What `base_url` returns when the variable is unset.
  def fallback_base_url(env = Rails.env)
    case env.to_s
    when "production" then PLACEHOLDER_PROD_BASE_URL
    when "staging" then PLACEHOLDER_STAGING_BASE_URL
    else default_local_base_url
    end
  end

  # Is `url` one of the non-functional placeholders, i.e. the deploy never set
  # the base URL?
  def placeholder?(url)
    [ PLACEHOLDER_PROD_BASE_URL, PLACEHOLDER_STAGING_BASE_URL ].include?(url.to_s.chomp("/"))
  end

  def default_local_base_url
    port = ENV["PORT"].presence || "3000"
    "http://localhost:#{port}"
  end
end
