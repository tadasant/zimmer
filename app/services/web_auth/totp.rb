# frozen_string_literal: true

module WebAuth
  # RFC 6238 time-based one-time passwords: HMAC-SHA1, six digits, 30-second
  # steps. Those are the parameters every authenticator app defaults to, so the
  # otpauth URI names them only to be explicit.
  #
  # Small enough to own outright rather than take a gem for. The RFC's own test
  # vectors are in test/services/web_auth/totp_test.rb.
  module Totp
    module_function

    DIGITS = 6
    PERIOD = 30
    # One step either side: a phone whose clock is up to ~30s off still works.
    DRIFT_STEPS = 1
    SECRET_BYTES = 20
    BASE32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

    # @return [String] a new base32 secret (32 characters, 160 bits)
    def generate_secret
      base32_encode(SecureRandom.random_bytes(SECRET_BYTES))
    end

    # The time step a code is for.
    def step_at(time) = time.to_i / PERIOD

    def code_at(secret, time) = code_for_step(secret, step_at(time))

    def code_for_step(secret, step)
      key = base32_decode(secret)
      hmac = OpenSSL::HMAC.digest("SHA1", key, [ step ].pack("Q>"))
      offset = hmac.getbyte(hmac.bytesize - 1) & 0x0f
      binary = hmac.byteslice(offset, 4).unpack1("N") & 0x7fffffff
      (binary % (10**DIGITS)).to_s.rjust(DIGITS, "0")
    end

    # The step `code` matches, or nil. A step at or before `after_step` never
    # matches, which is what stops a code from being accepted twice.
    #
    # @return [Integer, nil]
    def matching_step(secret, code, at: Time.current, after_step: nil)
      code = code.to_s.gsub(/\s/, "")
      return nil unless code.match?(/\A\d{#{DIGITS}}\z/o)

      now = step_at(at)
      (now - DRIFT_STEPS..now + DRIFT_STEPS).find do |step|
        next false if after_step && step <= after_step

        ActiveSupport::SecurityUtils.secure_compare(code_for_step(secret, step), code)
      end
    end

    # The name this deployment's entry carries in an authenticator app. It
    # names the host, because every Zimmer is "Zimmer": someone signed in to
    # two deployments would otherwise hold two identical-looking entries and
    # read codes off the wrong one. The port is dropped because a colon is
    # what separates the issuer from the account in the label.
    #
    # @param host [String, nil] e.g. "zimmer.example.com"
    # @return [String] e.g. "Zimmer (zimmer.example.com)", or "Zimmer" with no host
    def issuer_for(host)
      host = host.to_s.split(":").first.to_s.strip.downcase
      host.empty? ? "Zimmer" : "Zimmer (#{host})"
    end

    # The label an authenticator app shows for the entry: "issuer:account".
    def label(account:, issuer:) = "#{issuer.to_s.delete(":")}:#{account}"

    # What an authenticator app scans or opens to add the account. The label
    # prefix and the `issuer` parameter carry the same text, both
    # percent-encoded: a space as `%20` in both places, never `+` in the query,
    # which some apps show literally and then treat as a different issuer.
    def provisioning_uri(secret, account:, issuer:)
      issuer = issuer.to_s.delete(":")
      params = { secret: secret, issuer: issuer, algorithm: "SHA1", digits: DIGITS, period: PERIOD }
      query = params.map { |key, value| "#{key}=#{ERB::Util.url_encode(value.to_s)}" }.join("&")
      "otpauth://totp/#{ERB::Util.url_encode(label(account: account, issuer: issuer))}?#{query}"
    end

    def base32_encode(bytes)
      bits = bytes.unpack1("B*")
      bits.scan(/.{1,5}/).map { |chunk| BASE32[chunk.ljust(5, "0").to_i(2)] }.join
    end

    def base32_decode(text)
      bits = text.to_s.upcase.delete("= -").each_char.map do |char|
        index = BASE32.index(char) or raise ArgumentError, "not base32: #{char.inspect}"
        index.to_s(2).rjust(5, "0")
      end.join
      [ bits[0, bits.length - (bits.length % 8)] ].pack("B*")
    end
  end
end
