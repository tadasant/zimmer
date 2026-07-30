# frozen_string_literal: true

module ParameterStore
  # The service-account key could not be exchanged for an access token. Distinct
  # from StoreError because the fix is different: this one is the credential
  # itself, not what the credential is allowed to do.
  class AuthError < StandardError
    attr_reader :status

    def initialize(message, status)
      super(message)
      @status = status
    end
  end
end
