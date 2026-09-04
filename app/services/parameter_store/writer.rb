# frozen_string_literal: true

module ParameterStore
  # Builds the WRITE client from the process environment, and answers whether
  # Zimmer can write to the store at all.
  #
  # ## Why this is a second credential and not a wider first one
  #
  # Zimmer's resolver service account is created as *"reads parameter + secret
  # VALUES, writes nothing"* and holds exactly three read roles. That absence is
  # a property the app checks at runtime (Capabilities#least_privilege?) and the
  # provisioning runbook audits, and it is worth keeping: the resolver's key is
  # baked into the image and reaches every session's environment resolution path,
  # so widening it widens the blast radius of that one key to "can rewrite every
  # secret Zimmer holds".
  #
  # So the write path reads its own key from `ZIMMER_PARAMS_WRITER_SERVICE_ACCOUNT_KEY_JSON`,
  # held by a separate service account with the write roles on the same project.
  # Where it is absent, this falls back to the resolver's account — not to make
  # the feature work (it will not: the resolver holds no write permission and the
  # preflight below refuses before any call goes out), but so that a deployment
  # which *did* choose to widen the resolver is described accurately rather than
  # told the store is unconfigured.
  #
  # ABSENCE IS A NORMAL STATE, exactly as it is for the resolver. A Zimmer with
  # no writer credential boots and runs; the Pi tab says the write path is
  # closed, and names the grant that would open it.
  module Writer
    ENV_KEY_JSON = "ZIMMER_PARAMS_WRITER_SERVICE_ACCOUNT_KEY_JSON"

    # `identity` says WHICH credential a write would go out as, because "Zimmer
    # can write" and "Zimmer's read-only resolver has been given write" are very
    # different sentences to put in front of an operator.
    Configuration = Struct.new(:client, :reason, :identity, keyword_init: true) do
      def configured? = !client.nil?
      def dedicated_writer? = identity == :writer
    end

    module_function

    # @param env [Hash] the environment to read (injectable for tests)
    # @return [Configuration]
    def from_env(env = ENV)
      resolver = Resolver.from_env(env)
      unless resolver.configured?
        return Configuration.new(client: nil, identity: nil,
          reason: "the Parameter Store resolver is not configured (#{resolver.reason}), " \
                  "so there is no project to write into")
      end

      raw = env[ENV_KEY_JSON]
      # Environment values are bytes TAGGED UTF-8 and nothing guarantees they
      # are; String#presence goes through blank?, which RAISES on a mangled one.
      # Same guard, same reason, as Resolver.from_env.
      raw = nil unless raw.is_a?(String) && raw.valid_encoding?

      account, identity, reason = writer_account(raw, resolver, env)
      return Configuration.new(client: nil, identity: nil, reason: reason) if account.nil?

      Configuration.new(identity: identity, reason: nil, client: WriteClient.new(
        project_id: resolver.client.project_id,
        account: account,
        location: resolver.client.location,
        pm_api_base: env[Resolver::ENV_KEYS[:pm_api_base]],
        sm_api_base: env[Resolver::ENV_KEYS[:sm_api_base]],
        # The permissions probe goes to Cloud Resource Manager, so this seam has
        # to travel with the other two — without it the probe leaves the local
        # fake, reaches the real API, 401s, and every deployment reports "the
        # credential's permissions could not be confirmed".
        crm_api_base: env[Resolver::ENV_KEYS[:crm_api_base]]
      ))
    end

    # @return [Array(ServiceAccount, Symbol, nil), Array(nil, nil, String)]
    def writer_account(raw, resolver, env)
      if raw.blank?
        # The resolver's own account, named honestly. It will fail the
        # capability preflight in every deployment that has not widened it,
        # which is the intended outcome.
        return [ resolver.client.account, :resolver, nil ]
      end

      account, reason = ServiceAccount.parse(raw, token_url: env[Resolver::ENV_KEYS[:token_url]])
      return [ nil, nil, "#{ENV_KEY_JSON} #{reason}" ] if account.nil?

      [ account, :writer, nil ]
    end
    private_class_method :writer_account
  end
end
