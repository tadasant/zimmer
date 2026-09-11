# frozen_string_literal: true

module Webhooks
  # The HMAC primitives every webhook signature scheme is built from. Slack signs
  # `v0:<timestamp>:<body>` and GitHub signs the bare body, but both are HMAC-SHA256 in hex,
  # compared in constant time.
  module Hmac
    module_function

    def sha256_hex(secret, data)
      OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, data.to_s)
    end

    # Constant-time, so how much of a forged signature matched does not leak through how long
    # the rejection took.
    def matches?(expected, given)
      return false if expected.blank? || given.blank?

      ActiveSupport::SecurityUtils.secure_compare(expected.to_s, given.to_s)
    end
  end
end
