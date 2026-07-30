# frozen_string_literal: true

module ParameterStore
  # Builds Zimmer's Parameter Store resolver from the process environment, and
  # answers whether it is configured at all.
  #
  # The credential is read from ENV, not from Zimmer's encrypted credentials: it
  # is the key to the store that is meant to supersede that file, and keeping it
  # there would make rotating it require re-encrypting the very thing it replaces.
  #
  # ABSENCE IS A NORMAL STATE. A Zimmer with no resolver credential boots, runs,
  # and resolves every `${VAR}` from the encrypted credentials exactly as before;
  # the Connectors page says the store is not configured, and says where the
  # secrets go instead. Nothing here raises on a missing credential.
  module Resolver
    ENV_KEYS = {
      project_id: "ZIMMER_PARAMS_PROJECT_ID",
      location: "ZIMMER_PARAMS_LOCATION",
      key_json: "ZIMMER_PARAMS_RESOLVER_SERVICE_ACCOUNT_KEY_JSON",
      # Test seams, so an integration test can point the production client at a
      # local fake without a live GCP project.
      pm_api_base: "ZIMMER_PARAMS_PM_API_BASE",
      sm_api_base: "ZIMMER_PARAMS_SM_API_BASE",
      crm_api_base: "ZIMMER_PARAMS_CRM_API_BASE",
      token_url: "ZIMMER_PARAMS_TOKEN_URL"
    }.freeze

    Configuration = Struct.new(:client, :reason, keyword_init: true) do
      def configured? = !client.nil?
    end

    module_function

    # @param env [Hash] the environment to read (injectable for tests)
    # @return [Configuration] `client` is nil when the store is not wired up, and
    #   `reason` then says why in one human sentence.
    def from_env(env = ENV)
      project_id = env[ENV_KEYS[:project_id]].presence
      key_json = env[ENV_KEYS[:key_json]].presence

      if project_id.nil? && key_json.nil?
        return Configuration.new(client: nil,
          reason: "#{ENV_KEYS[:project_id]} and #{ENV_KEYS[:key_json]} are not set")
      end
      if project_id.nil?
        return Configuration.new(client: nil, reason: "#{ENV_KEYS[:project_id]} is not set")
      end
      if key_json.nil?
        return Configuration.new(client: nil, reason: "#{ENV_KEYS[:key_json]} is not set")
      end

      account, reason = ServiceAccount.parse(key_json, token_url: env[ENV_KEYS[:token_url]])
      if account.nil?
        return Configuration.new(client: nil, reason: "#{ENV_KEYS[:key_json]} #{reason}")
      end

      client = GcpClient.new(
        project_id: project_id,
        account: account,
        location: env[ENV_KEYS[:location]],
        pm_api_base: env[ENV_KEYS[:pm_api_base]],
        sm_api_base: env[ENV_KEYS[:sm_api_base]],
        crm_api_base: env[ENV_KEYS[:crm_api_base]]
      )

      Configuration.new(client: client, reason: nil)
    end
  end
end
