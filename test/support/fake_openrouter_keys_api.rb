# frozen_string_literal: true

require "socket"
require "json"
require "securerandom"

# A local stand-in for OpenRouter's key-management API (`/api/v1/keys`), for tests
# that drive the real OpenrouterKeyClient over HTTP. Keys live in memory; every
# request is recorded as [method, path, body, authorization].
#
#   api = FakeOpenrouterKeysApi.start
#   client = OpenrouterKeyClient.new(management_key: "mgmt", base_url: api.base_url)
#   ...
#   api.stop
class FakeOpenrouterKeysApi
  attr_reader :calls, :keys

  def self.start
    new.tap(&:start)
  end

  def initialize
    @calls = []
    @keys = {} # hash => record (includes "key", the plaintext, for assertions)
    @failures = {}
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

  def base_url = "http://127.0.0.1:#{@server.addr[1]}/api/v1"

  def client(management_key: "fake-management-key")
    OpenrouterKeyClient.new(management_key: management_key, base_url: base_url, open_timeout: 2, read_timeout: 5)
  end

  # Answer the next request whose method is `method` with `status`.
  def fail_next(method, status, message: "nope")
    @mutex.synchronize { @failures[method] = [ status, message ] }
  end

  # A key that exists at OpenRouter without Zimmer having minted it through this fake.
  def seed_key(name:, created_at: Time.current, hash: SecureRandom.hex(16))
    @mutex.synchronize do
      @keys[hash] = { "hash" => hash, "name" => name, "created_at" => created_at.utc.iso8601, "usage" => 0, "disabled" => false }
    end
    hash
  end

  def set_usage(hash, usage)
    @mutex.synchronize { @keys[hash]["usage"] = usage }
  end

  def live_hashes = @mutex.synchronize { @keys.keys }

  private

  def serve(socket)
    request_line = socket.gets.to_s
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.to_s.strip
    end
    body = socket.read(headers["content-length"].to_i).to_s
    method, target = request_line.split
    path, query = target.to_s.split("?", 2)

    status, payload = @mutex.synchronize do
      @calls << [ method, target, body, headers["authorization"] ]
      failure = @failures.delete(method)
      failure ? [ failure[0], { "error" => { "code" => failure[0], "message" => failure[1] } } ] : route(method, path, query, body)
    end

    text = JSON.generate(payload)
    socket.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\nContent-Length: #{text.bytesize}\r\nConnection: close\r\n\r\n#{text}")
  rescue StandardError
    nil
  ensure
    socket.close
  end

  def route(method, path, query, body)
    hash = path.delete_prefix("/api/v1/keys/") if path.start_with?("/api/v1/keys/")

    case [ method, hash ? :one : path ]
    when [ "POST", "/api/v1/keys" ]
      params = JSON.parse(body)
      hash = SecureRandom.hex(16)
      key = "sk-or-v1-#{SecureRandom.hex(32)}"
      record = { "hash" => hash, "name" => params["name"], "limit" => params["limit"],
                 "limit_reset" => params["limit_reset"], "expires_at" => params["expires_at"],
                 "created_at" => Time.now.utc.iso8601, "usage" => 0, "disabled" => false }
      @keys[hash] = record.merge("key" => key)
      [ 201, { "key" => key, "data" => record } ]
    when [ "GET", :one ]
      record = @keys[hash]
      record ? [ 200, { "data" => record.except("key") } ] : [ 404, { "error" => { "message" => "Not found" } } ]
    when [ "DELETE", :one ]
      @keys.delete(hash) ? [ 200, { "deleted" => true } ] : [ 404, { "error" => { "message" => "Not found" } } ]
    when [ "GET", "/api/v1/keys" ]
      offset = Rack::Utils.parse_query(query.to_s)["offset"].to_i
      page = @keys.values.reverse.drop(offset).first(OpenrouterKeyClient::PAGE_SIZE).map { |r| r.except("key") }
      [ 200, { "data" => page } ]
    else
      [ 404, { "error" => { "message" => "no route" } } ]
    end
  end
end
