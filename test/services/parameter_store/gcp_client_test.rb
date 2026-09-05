# frozen_string_literal: true

require "test_helper"
require "support/fake_parameter_store"

module ParameterStore
  class GcpClientTest < ActiveSupport::TestCase
    setup do
      @fake = FakeParameterStore.new
      @client = @fake.client
      @namespace = Namespace.static_namespace
    end

    test "resolves a secret parameter by dereferencing its Secret Manager pointer" do
      @fake.seed_secret("STRAD_API_KEY", "sk-live-value")

      assert_equal({ "STRAD_API_KEY" => "sk-live-value" }, @client.resolve(@namespace))
    end

    test "resolves a non-secret parameter straight from its envelope" do
      @fake.seed_plain("MCP_REGION", "us-east1")

      assert_equal({ "MCP_REGION" => "us-east1" }, @client.resolve(@namespace))
    end

    test "the secret value never touches a Parameter Manager payload" do
      @fake.seed_secret("STRAD_API_KEY", "sk-live-value")

      assert_equal "sk-live-value", @client.resolve(@namespace).fetch("STRAD_API_KEY")
      @fake.parameter_payloads.each do |payload|
        assert_no_match(/sk-live-value/, payload,
          "the parameter must hold a __REF__ pointer, never the secret itself")
      end
    end

    test "reads the newest version of a rotated secret" do
      @fake.seed_secret("STRAD_API_KEY", "old")
      @fake.secrets[Namespace.parameter_id(Namespace.parameter_path("STRAD_API_KEY"))] << "new"

      assert_equal "new", @client.resolve(@namespace).fetch("STRAD_API_KEY")
    end

    test "ignores a parameter in the project that Zimmer does not manage" do
      @fake.seed_unmanaged("someone-elses-parameter", {
        "path" => "#{Namespace.static_namespace}NOT_OURS", "secret" => false, "value" => "x"
      })

      assert_empty @client.resolve(@namespace)
    end

    test "ignores a managed parameter whose envelope path is outside the namespace" do
      @fake.seed_plain("OTHER", "x", path: "/zimmer/somewhere-else/mcp/static/OTHER")

      assert_empty @client.resolve(@namespace)
    end

    test "a parameter whose id collides with another path is not returned for it" do
      # `parameter_id` lowercases and folds punctuation, so these two paths share
      # one resource id. The envelope's own path is what tells them apart.
      colliding = "#{Namespace.static_namespace}other_name"
      assert_equal Namespace.parameter_id("#{Namespace.static_namespace}OTHER_NAME"),
        Namespace.parameter_id(colliding)

      @fake.seed_plain("ignored", "value", path: "/zimmer/other/mcp/static/OTHER_NAME")

      assert_empty @client.resolve(@namespace)
    end

    test "raises rather than returning an empty map when the store is unreachable" do
      @fake.seed_secret("STRAD_API_KEY", "sk-live-value")
      @fake.fail_with!(503)

      error = assert_raises(StoreError) { @client.resolve(@namespace) }
      assert_equal 503, error.status
    end

    test "a store error names the resource but never the response body" do
      @fake.fail_with!(403)

      error = assert_raises(StoreError) { @client.resolve(@namespace) }
      assert_match "/parameters", error.message
      assert_no_match(/error/, error.message, "the response body must not be echoed")
    end

    # --- the envelope's declared encoding --------------------------------------
    #
    # The value below is chosen so that base64 and base64url are NOT the same
    # string for it: `?` and `>` land on `/` and `+` in the standard alphabet and
    # on `_` and `-` in the url-safe one, and the url-safe spelling is unpadded.
    # A value that round-tripped identically under both would prove nothing about
    # which decoder is in use.

    ENCODES_DIFFERENTLY = "sk-live-?~>"

    test "the two alphabets really do disagree about the test value" do
      assert_equal "c2stbGl2ZS0_fj4", Base64.urlsafe_encode64(ENCODES_DIFFERENTLY, padding: false)
      assert_equal "c2stbGl2ZS0/fj4=", Base64.strict_encode64(ENCODES_DIFFERENTLY)
    end

    test "decodes a secret whose envelope declares base64url" do
      @fake.seed_console_secret("STRAD_API_KEY", ENCODES_DIFFERENTLY)

      assert_equal({ "STRAD_API_KEY" => ENCODES_DIFFERENTLY }, @client.resolve(@namespace))
    end

    test "a value a JSON payload could not carry literally survives the round trip" do
      # The reason the console encodes at all: `:render` substitutes the bytes
      # into the payload TEXT, and Parameter Manager rejects the result as an
      # injection when they carry JSON structure.
      tokens = %([{"id":"1","token":"t"}])
      @fake.seed_console_secret("STRAD_TOKENS", tokens)

      assert_equal tokens, @client.resolve(@namespace).fetch("STRAD_TOKENS")
    end

    test "an envelope with no encoding field is served byte-identically" do
      # The regression that would be worse than the bug: a value written before
      # the encoding existed, or by Zimmer's own WriteClient, is literal bytes.
      # It must not be decoded just because it happens to look decodable — and
      # this one does, being valid unpadded base64url in its own right.
      @fake.seed_secret("LITERAL", "c2stbGl2ZS0_fj4")

      assert_equal({ "LITERAL" => "c2stbGl2ZS0_fj4" }, @client.resolve(@namespace))
    end

    test "a non-secret parameter with no encoding field is served byte-identically" do
      @fake.seed_plain("MCP_REGION", "dXMtZWFzdDE")

      assert_equal({ "MCP_REGION" => "dXMtZWFzdDE" }, @client.resolve(@namespace))
    end

    test "refuses a value whose envelope declares an encoding this Zimmer does not implement" do
      @fake.seed_secret("FUTURE", "whatever", encoding: "rot13")

      resolved = @client.resolve_all([ @namespace ])

      assert_empty resolved.fetch(@namespace), "an unimplemented encoding must not be guessed at"
      assert_equal [ "FUTURE" ], resolved.undecodable
    end

    test "refusing an unimplemented encoding says so, naming the variable and not the value" do
      @fake.seed_secret("FUTURE", "sk-live-value", encoding: "rot13")
      logged = capture_parameter_store_errors { @client.resolve(@namespace) }

      assert_match(/FUTURE/, logged)
      assert_match(/rot13/, logged)
      assert_no_match(/sk-live-value/, logged, "the value must never reach the log")
    end

    test "refuses a value labelled base64url whose bytes are not base64url" do
      @fake.seed_secret("LIAR", "not base64url at all!", encoding: GcpClient::VALUE_ENCODING)

      resolved = @client.resolve_all([ @namespace ])

      assert_empty resolved.fetch(@namespace)
      assert_equal [ "LIAR" ], resolved.undecodable
    end

    test "refuses a value labelled base64url that decodes to invalid UTF-8" do
      @fake.seed_secret("BINARY", Base64.urlsafe_encode64("\xC3\x28".b, padding: false),
        encoding: GcpClient::VALUE_ENCODING)

      assert_empty @client.resolve(@namespace)
    end

    test "accepts the standard alphabet and padding under a base64url label" do
      # A value seeded by hand as plain base64 decodes to the same bytes, and is
      # refused only if it does not decode — never for how it is spelled.
      @fake.seed_secret("HAND_SEEDED", Base64.strict_encode64(ENCODES_DIFFERENTLY),
        encoding: GcpClient::VALUE_ENCODING)

      assert_equal ENCODES_DIFFERENTLY, @client.resolve(@namespace).fetch("HAND_SEEDED")
    end

    test "one refused parameter does not take the rest of the namespace down with it" do
      @fake.seed_console_secret("GOOD", "sk-live-good")
      @fake.seed_secret("BAD", "whatever", encoding: "rot13")

      resolved = @client.resolve_all([ @namespace ])

      assert_equal({ "GOOD" => "sk-live-good" }, resolved.fetch(@namespace))
      assert_equal [ "BAD" ], resolved.undecodable
    end

    test "nothing is undecodable when every envelope is honoured" do
      @fake.seed_console_secret("GOOD", "sk-live-good")

      assert_empty @client.resolve_all(Namespace.read_namespaces).undecodable
    end

    # --- resolve_all -----------------------------------------------------------

    test "resolve_all buckets each namespace separately, in one pass over the project" do
      @fake.seed_secret("MIGRATED", "new")
      @fake.seed_secret("NOT_YET", "old", path: "#{Namespace.legacy_static_namespace}NOT_YET")
      before = @fake.requests.size

      resolved = @fake.client.resolve_all(Namespace.read_namespaces)

      assert_equal({ "MIGRATED" => "new" }, resolved.fetch(Namespace.static_namespace))
      assert_equal({ "NOT_YET" => "old" }, resolved.fetch(Namespace.legacy_static_namespace))
      # One list, then one versions-list and one render per parameter: the same
      # traffic a single-namespace resolve costs. Reading the pre-rename
      # namespace alongside the canonical one is meant to be free.
      assert_equal 5, @fake.requests.size - before
    end

    test "resolve_all keys every namespace asked for, empty ones included" do
      resolved = @fake.client.resolve_all(Namespace.read_namespaces)

      assert_equal Namespace.read_namespaces, resolved.keys
      assert resolved.values.all?(&:empty?)
    end

    test "resolve_all applies the envelope-path fence to each namespace on its own" do
      @fake.seed_plain("ELSEWHERE", "x", path: "/zimmer/somewhere-else/secrets/static/ELSEWHERE")

      resolved = @fake.client.resolve_all(Namespace.read_namespaces)

      assert resolved.values.all?(&:empty?)
    end

    test "held_permissions reports the subset Google says the credential holds" do
      @fake.held_permissions = [ Capabilities::READ_SECRET_VALUE ]

      assert_equal [ Capabilities::READ_SECRET_VALUE ],
        @client.held_permissions(Capabilities::PROBED_PERMISSIONS)
    end

    private

    # Everything the block logs at error level, as one string.
    def capture_parameter_store_errors
      io = StringIO.new
      previous = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(io).tap { |l| l.level = Logger::ERROR }
      yield
      io.string
    ensure
      Rails.logger = previous
    end
  end
end
