# frozen_string_literal: true

module SecretProviders
  # The process environment. Last link in the chain, and the only one with no
  # durable home: a value here lives as long as the container does.
  class Env
    LABEL = "the process environment"

  # Fixed badge string. strad's Secrets Console ships the same three labels
  # (Rails Credentials / GSM / ENV) so the two lists can be scanned side by side
  # and compared; do not reword them independently.
  BADGE = "ENV"

    def initialize(env = ENV)
      @env = env
    end

    def name = "env"
    def label = LABEL
    def badge = BADGE
    # `variable` is accepted and ignored: every provider takes it so a caller can
    # name the one it is asking about, and only the Parameter Store link — which
    # reads more than one namespace — has a different answer per variable.
    def badge_title(_variable = nil) = "Resolved from the process environment"

    def get(variable)
      value = @env[variable]
      value.presence
    end

    def has?(variable) = !get(variable).nil?

    def invalidate(_variable = nil) = nil
  end
end
