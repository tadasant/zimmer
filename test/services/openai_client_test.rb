# frozen_string_literal: true

require "test_helper"
require "socket"

# Against a real local HTTP listener: what goes over the wire is the contract.
class OpenaiClientTest < ActiveSupport::TestCase
  class Listener
    attr_reader :requests

    def initialize(status: 200, body: {})
      @status = status
      @body = JSON.generate(body)
      @requests = []
      @socket = TCPServer.new("127.0.0.1", 0)
      @thread = Thread.new do
        loop { serve(@socket.accept) }
      rescue IOError, Errno::EBADF
        nil
      end
    end

    def base_url = "http://127.0.0.1:#{@socket.addr[1]}/v1"

    def stop
      @socket.close
      @thread.join(2)
    end

    private

    def serve(connection)
      request_line = connection.gets
      headers = {}
      while (line = connection.gets) && line.strip != ""
        name, value = line.split(":", 2)
        headers[name.strip.downcase] = value.to_s.strip
      end
      @requests << { line: request_line.strip, headers: headers, body: JSON.parse(connection.read(headers["content-length"].to_i)) }
      connection.write("HTTP/1.1 #{@status} X\r\nContent-Type: application/json\r\nContent-Length: #{@body.bytesize}\r\nConnection: close\r\n\r\n#{@body}")
    ensure
      connection.close
    end
  end

  teardown { @listener&.stop }

  test "posts chat completions with the key as a bearer token" do
    @listener = Listener.new(body: { "choices" => [ { "message" => { "content" => "hi" } } ] })

    result = OpenaiClient.new(api_key: "sk-test", base_url: @listener.base_url).chat_completion(model: "gpt-6-luna", messages: [])

    assert_equal "hi", result.dig("choices", 0, "message", "content")
    request = @listener.requests.sole
    assert_equal "POST /v1/chat/completions HTTP/1.1", request[:line]
    assert_equal "Bearer sk-test", request[:headers]["authorization"]
    assert_equal "gpt-6-luna", request[:body]["model"]
  end

  test "mints realtime client secrets at /realtime/client_secrets" do
    @listener = Listener.new(body: { "value" => "ek_1", "expires_at" => 1 })

    result = OpenaiClient.new(api_key: "sk-test", base_url: @listener.base_url).create_realtime_client_secret(session: { type: "realtime" })

    assert_equal "ek_1", result["value"]
    assert_equal "POST /v1/realtime/client_secrets HTTP/1.1", @listener.requests.sole[:line]
  end

  test "an error status raises with OpenAI's own message" do
    @listener = Listener.new(status: 401, body: { "error" => { "message" => "Incorrect API key provided" } })

    error = assert_raises(OpenaiClient::Error) do
      OpenaiClient.new(api_key: "sk-bad", base_url: @listener.base_url).chat_completion(model: "m", messages: [])
    end
    assert_equal 401, error.status
    assert_match(/OpenAI answered 401: Incorrect API key provided/, error.message)
  end

  test "no key means the client refuses to exist, rather than sending an empty bearer" do
    assert_raises(OpenaiClient::NotConfiguredError) { OpenaiClient.new(api_key: nil) }
  end

  test "the key has its own name, so it never reaches Codex or Pi as OPENAI_API_KEY" do
    assert_equal "LIVE_OPENAI_API_KEY", OpenaiClient::API_KEY_VARIABLE
    chain = SecretProviders::Chain.new([ SecretProviders::Env.new({ "LIVE_OPENAI_API_KEY" => "sk-live", "OPENAI_API_KEY" => "sk-other" }) ])
    assert_equal "sk-live", OpenaiClient.api_key(chain: chain)
    assert_nil OpenaiClient.api_key(chain: SecretProviders::Chain.new([ SecretProviders::Env.new({ "OPENAI_API_KEY" => "sk-other" }) ]))
  end
end
