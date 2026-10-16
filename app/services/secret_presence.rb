# frozen_string_literal: true

# Whether one store-backed `${VAR}` resolves, and from which link of the
# SecretProviders chain — the whole of what a Zimmer page says about a secret it
# depends on.
#
# Zimmer does not manage its own secret store. It reads values at runtime,
# through the ordinary resolution chain, and that is all: there is no write, no
# delete, and no fingerprint or other read-back of a value on any surface.
# Setting or rotating a value happens in the secrets console that administers
# the store ({SecretsLocation.store_console}), never through Zimmer. So this
# class answers "is it set", "from where", and "where does it belong", and
# nothing that would need the value to answer.
class SecretPresence
  # A plain, closed struct: a hash of whatever happened to be handy is how a
  # value ends up on a page by accident.
  #
  # `store_configured` is whether the chain has a Parameter Store link at all —
  # without one, `path` names an address nothing reads. `in_store` is whether the
  # value that resolves came from that link, as opposed to credentials or ENV,
  # which the console cannot rotate or delete.
  Status = Struct.new(:variable, :present, :provider_label, :provider_badge, :path,
    :store_configured, :in_store, keyword_init: true) do
    def present? = !!present
    def store_configured? = !!store_configured
    def in_store? = !!in_store
  end

  # @param variable [String] an environment-variable name, e.g. LIVE_OPENAI_API_KEY
  # @param chain [SecretProviders::Chain] injectable for tests
  # @return [Status] never carries the value, by construction.
  def self.for(variable, chain: SecretProviders.chain)
    provider = provider_for(variable, chain)

    Status.new(
      variable: variable,
      present: !provider.nil?,
      provider_label: provider&.label,
      provider_badge: provider&.badge,
      path: ParameterStore::Namespace.parameter_path(variable),
      store_configured: chain.providers.any? { |link| link.is_a?(SecretProviders::ParameterStoreProvider) },
      in_store: provider.is_a?(SecretProviders::ParameterStoreProvider)
    )
  end

  # A store that cannot be consulted reads as "not set": the page has to render
  # through an outage, and "we could not ask" is closer to "not set" than to
  # anything else it can say.
  def self.provider_for(variable, chain)
    chain.provider_for(variable)
  rescue ParameterStore::AuthError, ParameterStore::StoreError
    nil
  end
  private_class_method :provider_for
end
