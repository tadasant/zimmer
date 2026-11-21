# frozen_string_literal: true

require "net/http"

module OauthClientIdentity
  # A signer whose private key lives in Google Cloud KMS and cannot leave it.
  # Zimmer holds only the key version's resource name and a service-account
  # credential allowed to call `asymmetricSign` on it: it can sign, and nothing
  # it holds lets anyone copy the key out.
  #
  # Two REST calls, no Google SDK:
  #
  #   GET  {api}/v1/{version}/publicKey        -> { pem, algorithm }   (cached)
  #   POST {api}/v1/{version}:asymmetricSign   { digest: { sha256 } } -> { signature }
  #
  # Supported key algorithms are the ones that map onto RS256 and ES256 (see
  # ALGORITHMS). Anything else is refused when the public key is first read.
  class GcpKmsSigner < Signer
    DEFAULT_API_BASE = "https://cloudkms.googleapis.com"
    REQUEST_TIMEOUT = 10

    ALGORITHMS = {
      "RSA_SIGN_PKCS1_2048_SHA256" => RS256,
      "RSA_SIGN_PKCS1_3072_SHA256" => RS256,
      "RSA_SIGN_PKCS1_4096_SHA256" => RS256,
      "EC_SIGN_P256_SHA256" => ES256
    }.freeze

    VERSION_NAME = %r{\Aprojects/[^/]+/locations/[^/]+/keyRings/[^/]+/cryptoKeys/[^/]+/cryptoKeyVersions/[^/]+\z}

    attr_reader :version_name

    # @param version_name [String] projects/P/locations/L/keyRings/R/cryptoKeys/K/cryptoKeyVersions/N
    # @param account [ParameterStore::ServiceAccount, nil] mints the access token
    # @param api_base [String, nil] test seam
    def initialize(version_name, account:, api_base: nil)
      super()
      raise Unavailable, "#{version_name.inspect} is not a KMS cryptoKeyVersion resource name" unless version_name.to_s.match?(VERSION_NAME)

      @version_name = version_name
      @account = account
      @api_base = (api_base.presence || DEFAULT_API_BASE).chomp("/")
      @mutex = Mutex.new
    end

    def alg
      load_public_key!
      @alg
    end

    def public_key
      load_public_key!
      @public_key
    end

    def sign(signing_input)
      digest = OpenSSL::Digest::SHA256.digest(signing_input)
      body = request(:post, "#{@api_base}/v1/#{@version_name}:asymmetricSign",
        { digest: { sha256: Base64.strict_encode64(digest) } })
      signature = Base64.decode64(body["signature"].to_s)
      raise Unavailable, "KMS returned no signature for #{@version_name}" if signature.empty?

      alg == ES256 ? Signer.der_to_raw_ecdsa(signature) : signature
    end

    private

    # The public key is immutable for a key version, so it is read once per
    # process. A failure is not cached: the next call tries again.
    def load_public_key!
      return if @public_key

      @mutex.synchronize do
        return if @public_key

        body = request(:get, "#{@api_base}/v1/#{@version_name}/publicKey")
        algorithm = ALGORITHMS[body["algorithm"]]
        unless algorithm
          raise Unavailable, "KMS key #{@version_name} has algorithm #{body['algorithm'].inspect}; " \
            "supported: #{ALGORITHMS.keys.join(', ')}"
        end

        @alg = algorithm
        @public_key = OpenSSL::PKey.read(body["pem"].to_s)
      end
    rescue OpenSSL::PKey::PKeyError
      raise Unavailable, "KMS returned a public key for #{@version_name} that could not be read"
    end

    def request(method, url, payload = nil)
      raise Unavailable, "no GCP service account is configured to call KMS (#{KeySet::KMS_CREDENTIAL_ENV})" unless @account

      uri = URI(url)
      req = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
      req["Authorization"] = "Bearer #{@account.access_token}"
      req["Accept"] = "application/json"
      if payload
        req["Content-Type"] = "application/json"
        req.body = payload.to_json
      end

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https",
        open_timeout: REQUEST_TIMEOUT, read_timeout: REQUEST_TIMEOUT) { |http| http.request(req) }
      unless response.is_a?(Net::HTTPSuccess)
        raise Unavailable, "KMS #{method.to_s.upcase} for #{@version_name} answered #{response.code}"
      end

      JSON.parse(response.body.to_s)
    rescue ParameterStore::AuthError => e
      raise Unavailable, "could not get a GCP access token for KMS: #{e.message}"
    rescue JSON::ParserError
      raise Unavailable, "KMS answered #{@version_name} with a body that is not JSON"
    rescue Timeout::Error, SystemCallError, SocketError, OpenSSL::SSL::SSLError => e
      raise Unavailable, "KMS could not be reached (#{e.class})"
    end
  end
end
