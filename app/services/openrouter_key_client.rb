# frozen_string_literal: true

require "net/http"

# OpenRouter's key-management API, spoken with a management key.
#
# A management key can create, read, update and delete the account's API keys,
# and cannot itself call a completion. That split is what makes PiSessionKeys
# possible: the backend holds the management key and hands each Pi spawn a key
# it minted, capped in dollars and in time, instead of the account's long-lived
# inference key.
#
#   POST   /keys           { name, limit, expires_at } -> { key, data: { hash, ... } }
#   GET    /keys/{hash}    -> { data: { usage, disabled, ... } }
#   DELETE /keys/{hash}
#   GET    /keys?offset=N  -> { data: [ ... ] }, newest first, 100 per page
#
# The plaintext key is in the create response only, and `hash` is the record's
# identifier, not the secret. Nothing here logs either key, and no error message
# carries a request header or a response's `key` field.
class OpenrouterKeyClient
  DEFAULT_BASE_URL = "https://openrouter.ai/api/v1"
  # Deliberately not a generic `OPENROUTER_BASE_URL`: tooling that proxies
  # inference could set that name, and every call here carries the management key.
  BASE_URL_VARIABLE = "OPENROUTER_KEY_MANAGEMENT_BASE_URL"

  OPEN_TIMEOUT_SECONDS = 5
  READ_TIMEOUT_SECONDS = 15

  # A page of `GET /keys`. OpenRouter documents 100.
  PAGE_SIZE = 100

  class Error < StandardError
    attr_reader :status

    def initialize(message, status: nil)
      super(message)
      @status = status
    end

    def not_found? = status == 404
  end

  # The minted key and the identifier to revoke it by. A plain class rather
  # than a Struct, so nothing (`to_h`, `to_a`, `pp`) prints the plaintext.
  class Minted
    attr_reader :key, :key_hash, :expires_at

    def initialize(key:, key_hash:, expires_at:)
      @key = key
      @key_hash = key_hash
      @expires_at = expires_at
    end

    def inspect = "#<OpenrouterKeyClient::Minted key_hash=#{key_hash.inspect} key=[REDACTED]>"
    alias_method :to_s, :inspect
    alias_method :pretty_inspect, :inspect
  end

  def self.base_url = ENV.fetch(BASE_URL_VARIABLE, "").presence || DEFAULT_BASE_URL

  def initialize(management_key:, base_url: self.class.base_url,
                 open_timeout: OPEN_TIMEOUT_SECONDS, read_timeout: READ_TIMEOUT_SECONDS)
    raise ArgumentError, "management key is blank" if management_key.blank?

    @management_key = management_key
    @base_url = base_url.chomp("/")
    @open_timeout = open_timeout
    @read_timeout = read_timeout
  end

  def inspect = "#<OpenrouterKeyClient base_url=#{@base_url.inspect}>"

  # @param name [String] 1..256 characters
  # @param limit_usd [Numeric] the key's spend cap; it does not reset
  # @param expires_at [Time] OpenRouter wants second precision, UTC
  # @return [Minted]
  def create(name:, limit_usd:, expires_at:)
    body = {
      name: name,
      limit: limit_usd.to_f,
      limit_reset: nil,
      expires_at: expires_at.utc.iso8601
    }
    parsed = request(Net::HTTP::Post, "/keys", body)
    key = parsed["key"]
    hash = parsed.dig("data", "hash")
    raise Error, "OpenRouter created a key but returned no key or hash" if key.blank? || hash.blank?

    Minted.new(key: key, key_hash: hash, expires_at: expires_at)
  end

  # @return [Hash] the key's record (`usage`, `disabled`, `limit_remaining`, ...)
  def get(hash)
    request(Net::HTTP::Get, "/keys/#{encode(hash)}").fetch("data", {})
  end

  def delete(hash)
    request(Net::HTTP::Delete, "/keys/#{encode(hash)}")
    true
  end

  # One page of the account's keys, newest first.
  # @return [Array<Hash>]
  def list(offset: 0)
    Array(request(Net::HTTP::Get, "/keys?offset=#{Integer(offset)}")["data"])
  end

  private

  def encode(hash) = URI.encode_www_form_component(hash.to_s)

  def request(klass, path, body = nil)
    uri = URI("#{@base_url}#{path}")
    req = klass.new(uri)
    req["Authorization"] = "Bearer #{@management_key}"
    req["Accept"] = "application/json"
    if body
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body)
    end

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
      open_timeout: @open_timeout, read_timeout: @read_timeout) { |http| http.request(req) }

    parsed = parse(response.body)
    return parsed if response.is_a?(Net::HTTPSuccess)

    raise Error.new("OpenRouter answered #{response.code} to #{klass::METHOD} /keys: #{error_message(parsed, response)}",
      status: response.code.to_i)
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    raise Error, "OpenRouter did not answer in time (#{e.class.name.demodulize})"
  rescue SocketError, SystemCallError, OpenSSL::SSL::SSLError, IOError => e
    raise Error, "Could not reach OpenRouter: #{e.class.name}"
  rescue Error
    raise
  rescue StandardError => e
    # Net::WriteTimeout, Net::HTTPBadResponse, a decompression error. The class
    # only: an exception message from deep in Net::HTTP is not ours to vouch for.
    raise Error, "OpenRouter request failed: #{e.class.name}"
  end

  def parse(body)
    parsed = JSON.parse(body.to_s)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  # Only the provider's `error.message`, never the body: a create response that
  # failed half-way could in principle still carry a `key`.
  def error_message(parsed, response)
    message = parsed.dig("error", "message") if parsed["error"].is_a?(Hash)
    (message.presence || response.message.to_s).to_s.truncate(300)
  end
end
