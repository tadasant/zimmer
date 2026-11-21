# frozen_string_literal: true

require "socket"
require "openssl"
require "base64"

# Google Cloud KMS's two asymmetric-signing calls and Google's OAuth token
# endpoint, over real HTTP, for OauthClientIdentity::GcpKmsSigner tests.
#
#   kms = FakeGcpKms.start(key: OpenSSL::PKey::EC.generate("prime256v1"))
#   kms.api_base   # ZIMMER_OAUTH_CLIENT_KMS_API_BASE
#   kms.token_url  # ZIMMER_PARAMS_TOKEN_URL
#   kms.stop
#
# Like KMS, it signs the SHA-256 DIGEST it is sent, never the message, and
# returns an ECDSA signature DER-encoded. It answers only the key version it was
# started with, and only with the access token its token endpoint minted.
class FakeGcpKms
  ACCESS_TOKEN = "fake-gcp-access-token"

  attr_reader :requests, :version_name
  attr_accessor :algorithm, :refuse_sign, :corrupt_signature

  def self.start(...) = new(...).tap(&:start)

  def initialize(key:, version_name: "projects/p/locations/global/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1", algorithm: nil)
    @key = key
    @version_name = version_name
    @algorithm = algorithm || (key.is_a?(OpenSSL::PKey::RSA) ? "RSA_SIGN_PKCS1_2048_SHA256" : "EC_SIGN_P256_SHA256")
    @requests = []
    @mutex = Mutex.new
  end

  def start
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new { loop { serve(@server.accept) } rescue IOError }
    self
  end

  def stop
    @server&.close
    @thread&.join(2)
  end

  def api_base = "http://127.0.0.1:#{@server.addr[1]}"

  def token_url = "#{api_base}/token"

  def paths = @mutex.synchronize { @requests.map { |r| "#{r[:method]} #{r[:path]}" } }

  private

  def serve(socket)
    method, path = socket.gets.to_s.split(" ")
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.to_s.strip
    end
    body = socket.read(headers["content-length"].to_i)
    @mutex.synchronize { @requests << { method: method, path: path, headers: headers, body: body } }
    status, payload = route(method, path, headers, body)
    text = JSON.generate(payload)
    socket.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\nContent-Length: #{text.bytesize}\r\nConnection: close\r\n\r\n#{text}")
  ensure
    socket.close
  end

  def route(method, path, headers, body)
    return [ 200, { access_token: ACCESS_TOKEN, expires_in: 3600 } ] if method == "POST" && path == "/token"
    return [ 401, { error: { code: 401 } } ] unless headers["authorization"] == "Bearer #{ACCESS_TOKEN}"

    if method == "GET" && path == "/v1/#{@version_name}/publicKey"
      [ 200, { pem: @key.public_to_pem, algorithm: @algorithm, name: @version_name } ]
    elsif method == "POST" && path == "/v1/#{@version_name}:asymmetricSign"
      return [ 403, { error: { code: 403, status: "PERMISSION_DENIED" } } ] if refuse_sign

      digest = Base64.strict_decode64(JSON.parse(body).dig("digest", "sha256"))
      signature = @key.is_a?(OpenSSL::PKey::RSA) ? @key.sign_raw("SHA256", digest) : @key.dsa_sign_asn1(digest)
      signature = signature.reverse if corrupt_signature
      [ 200, { signature: Base64.strict_encode64(signature), name: @version_name } ]
    else
      [ 404, { error: { code: 404 } } ]
    end
  end
end
