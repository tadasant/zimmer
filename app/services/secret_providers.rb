# frozen_string_literal: true

# The ordered set of places a `${VAR}` can come from.
#
# ## Precedence, and why
#
#   1. **Parameter Store** (Google Parameter Manager + Secret Manager), when a
#      resolver credential is configured.
#   2. **Rails encrypted credentials** (`mcp_secrets` in
#      `config/credentials/{env}.yml.enc`), via SecretsLoader.
#   3. **Process ENV.**
#
# The store goes FIRST so migration is one reversible step per secret: write the
# value into the store and it takes effect; delete it from the store and the
# encrypted-credentials value is live again. Were the order reversed, adding a
# secret to the store would do nothing until someone also deleted it from the
# credentials file — a change with no visible effect is a change people stop
# trusting.
#
# There is no flag day. With no store configured the chain is exactly the two
# links Zimmer has always had.
#
# ## A miss is not an error
#
# `get` returns nil ONLY when a provider reached its backend and the name was not
# there. A provider that could not reach its backend RAISES, and the chain does
# not catch it. Silently falling through to the encrypted-credentials copy during
# a store outage is how a rotated credential comes back from the dead — the
# fallback exists to carry secrets that have not migrated yet, not to paper over
# an unreachable store.
module SecretProviders
  module_function

  # The process-wide chain. Built once, because the Parameter Store link owns a
  # snapshot cache and an access token that should be shared.
  #
  # @return [SecretProviders::Chain]
  def chain
    # Puma serves concurrently, and the Parameter Store link owns a snapshot
    # cache and an access token worth sharing, so two threads racing to build
    # their own would each pay for a separate namespace read.
    @chain_mutex ||= Mutex.new
    @chain || @chain_mutex.synchronize { @chain ||= build }
  end

  # Drop the memoized chain (and any cached values inside it). Used by tests and
  # by the catalog-refresh path.
  def reset!
    @chain = nil
  end

  # @param env [Hash]
  # @return [SecretProviders::Chain]
  def build(env: ENV)
    configuration = ParameterStore::Resolver.from_env(env)
    links = []
    links << ParameterStoreProvider.new(configuration.client) if configuration.configured?
    links << RailsCredentials.new
    links << Env.new(env)

    Chain.new(links)
  end

  # Whether the Parameter Store link is present, and why not when it is absent.
  # The Connectors page reports this so "the store is not wired up" never reads
  # as "your secret is missing".
  #
  # @return [ParameterStore::Resolver::Configuration]
  def parameter_store_configuration(env: ENV)
    ParameterStore::Resolver.from_env(env)
  end
end
