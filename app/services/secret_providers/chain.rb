# frozen_string_literal: true

module SecretProviders
  # Try each provider in order; the first definitive hit wins.
  #
  # A provider that RAISES does not fall through — see the note on miss-vs-error
  # in SecretProviders.
  class Chain
    attr_reader :providers

    def initialize(providers)
      raise ArgumentError, "a chain needs at least one provider" if providers.empty?

      @providers = providers
    end

    def name = "chain(#{providers.map(&:name).join(',')})"

    # @param variable [String]
    # @return [String, nil] nil when every provider answered "not here".
    def get(variable)
      providers.each do |provider|
        value = provider.get(variable)
        return value unless value.nil?
      end
      nil
    end

    # Which provider holds `variable`, without returning the value.
    #
    # This is what status surfaces use. It exists so the Connectors page can say
    # "set, from the Parameter Store" without a secret ever entering a view.
    #
    # @return [SecretProviders::Env, SecretProviders::RailsCredentials, SecretProviders::ParameterStoreProvider, nil]
    def provider_for(variable)
      providers.find { |provider| provider.has?(variable) }
    end

    def has?(variable) = !provider_for(variable).nil?

    # Every name any link holds — never a value. For the one caller that has to
    # discover variables by prefix rather than ask for a known one:
    # GhTokenProvisioner, finding the GH_TOKEN__<OWNER> tokens an operator seeded.
    #
    # Unlike {#get}, a link that raises is skipped rather than propagated: a
    # listing is a best-effort discovery pass, and the caller resolves every name
    # it finds through {#get}, which keeps the miss-vs-error rule.
    #
    # @return [Array<String>]
    def names
      providers.flat_map do |provider|
        provider.respond_to?(:names) ? provider.names : []
      rescue StandardError
        []
      end.uniq
    end

    def invalidate(variable = nil)
      providers.each { |provider| provider.invalidate(variable) }
    end
  end
end
