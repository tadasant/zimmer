# frozen_string_literal: true

# The secret bundle a session is prepared from: every name the Parameter Store
# and Rails encrypted credentials hold, with the store winning — the same order
# SecretProviders.chain resolves a single `${VAR}` in.
#
# Two consumers draw on it, and every session genesis reaches both through
# AirPrepareService (a Slack, schedule, GitHub, email or WhatsApp trigger, the
# API, MCP and the web UI all create a session that AgentSessionJob prepares the
# same way):
#
#   - **`air prepare`'s subprocess environment.** `@pulsemcp/air-secrets-env`
#     resolves the `${VAR}`s in the selected root, MCP servers and hooks from
#     `process.env`, and fails the prepare on one it cannot find. This process
#     is Zimmer's own, not the agent's: what it resolves lands in the runtime's
#     MCP config for the servers that declared it, and nowhere else.
#   - **The clone's `.env`** (SessionEnvFile), narrowed by SessionSecretScope to
#     the names this session's own artifacts ask for. That narrowing is what
#     keeps the agent's environment to what its artifacts need; widening the
#     bundle it draws from does not widen it.
#
# Built from encrypted credentials alone, the bundle left a secret kept only in
# the store out of both — so a root or server that needed it failed every
# session with `air_secret_unresolvable` before its first turn.
#
# ## What is not in it
#
# **Process ENV.** The `air prepare` subprocess inherits it anyway (Open3 merges
# this hash over the parent environment, which keeps ENV the lowest-precedence
# link, as in the chain), and the worker's environment holds Zimmer's own
# secrets — `RAILS_MASTER_KEY`, `SECRET_KEY_BASE` — that must never be eligible
# for a clone's `.env` by way of a skill that happens to mention one.
#
# ## A store that cannot be read
#
# The bundle falls back to encrypted credentials alone, with a warning — exactly
# what every session was prepared from before the store was consulted here. The
# chain's own rule is to raise rather than fall through, so a rotated credential
# cannot come back from the dead; a whole-bundle read cannot honour that per
# name, and failing every session spawn for the length of a store outage is the
# worse trade. The snapshot cache serves its last good read through a short
# outage, so this only bites on a cold start against a store that is down.
module SessionSecrets
  module_function

  # @param chain [SecretProviders::Chain]
  # @return [Hash{String => String}] name => value, never with a blank value
  def all(chain: SecretProviders.chain)
    credentials = SecretsLoader.all
    store = chain.providers.find { |provider| provider.is_a?(SecretProviders::ParameterStoreProvider) }
    return credentials if store.nil?

    credentials.merge(store_values(store))
  rescue ParameterStore::StoreError, ParameterStore::AuthError => e
    # The class only: a store error's message can carry a resource path.
    Rails.logger.warn "[SessionSecrets] Parameter Store unreadable, using encrypted credentials only: #{e.class}"
    credentials || {}
  end

  def store_values(store)
    store.names.each_with_object({}) do |name, values|
      value = store.get(name)
      values[name] = value if value.present?
    end
  end
end
