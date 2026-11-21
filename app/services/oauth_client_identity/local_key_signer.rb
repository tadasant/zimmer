# frozen_string_literal: true

module OauthClientIdentity
  # A signer over a private key held in this process: development, tests and the
  # open-source build. Production uses GcpKmsSigner, whose key never leaves KMS.
  #
  # The key is an RSA (2048 bits or more) or EC P-256 private key as PEM, or as
  # base64 of the PEM — the form a Kamal env-file can carry, since it cannot
  # carry a PEM's newlines.
  #
  #   openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 | base64 -w0
  class LocalKeySigner < Signer
    MIN_RSA_BITS = 2048

    # @param value [String] PEM, or base64 of PEM
    # @raise [Unavailable] when it is not a usable private key
    def initialize(value)
      super()
      @key = load(value.to_s.strip)
    end

    def alg
      @key.is_a?(OpenSSL::PKey::RSA) ? RS256 : ES256
    end

    def public_key
      @public_key ||= OpenSSL::PKey.read(@key.public_to_pem)
    end

    def sign(signing_input)
      signature = @key.sign(OpenSSL::Digest.new("SHA256"), signing_input)
      alg == ES256 ? Signer.der_to_raw_ecdsa(signature) : signature
    end

    private

    def load(value)
      pem = value.include?("BEGIN") ? value.gsub('\n', "\n") : Base64.decode64(value)
      key = OpenSSL::PKey.read(pem)
      raise Unavailable, "the local signing key must be a private key" unless key.private?

      case key
      when OpenSSL::PKey::RSA
        raise Unavailable, "the local RSA signing key must be at least #{MIN_RSA_BITS} bits" if key.n.num_bits < MIN_RSA_BITS
      when OpenSSL::PKey::EC
        raise Unavailable, "the local EC signing key must be on P-256" unless key.group.curve_name == "prime256v1"
      else
        raise Unavailable, "the local signing key must be RSA or EC P-256"
      end
      key
    rescue OpenSSL::PKey::PKeyError, ArgumentError
      # Never quote the value: a malformed key is still a key.
      raise Unavailable, "the local signing key could not be read as a PEM private key"
    end
  end
end
