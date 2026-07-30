# frozen_string_literal: true

module ParameterStore
  # A non-2xx answer from Parameter Manager or Secret Manager.
  #
  # There is deliberately no transient/permanent split here. Callers classify by
  # `status` at the point where the distinction means something (404 is "absent",
  # 403 is "the credential is wrong", 5xx is "try again later"), which keeps the
  # judgement next to the code that acts on it.
  #
  # The message names a resource, never a value: Google's error bodies for the
  # render and access verbs can quote the payload, so a body is never
  # interpolated into the message.
  class StoreError < StandardError
    attr_reader :status

    def initialize(message, status)
      super(message)
      @status = status
    end
  end
end
