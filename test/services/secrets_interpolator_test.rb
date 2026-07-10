# frozen_string_literal: true

require "test_helper"

class SecretsInterpolatorTest < ActiveSupport::TestCase
  setup do
    @interpolator = SecretsInterpolator.new
  end

  test "resolve substitutes a value from ENV" do
    ENV["SECRETS_INTERP_TEST_VAR"] = "from_env"
    assert_equal "from_env", @interpolator.resolve("${SECRETS_INTERP_TEST_VAR}")
  ensure
    ENV.delete("SECRETS_INTERP_TEST_VAR")
  end

  test "resolve prefers SecretsLoader over ENV" do
    ENV["SECRETS_INTERP_TEST_VAR"] = "from_env"
    SecretsLoader.stub(:exists?, ->(name) { name == "SECRETS_INTERP_TEST_VAR" }) do
      SecretsLoader.stub(:get, ->(_name) { "from_secrets" }) do
        assert_equal "from_secrets", @interpolator.resolve("${SECRETS_INTERP_TEST_VAR}")
      end
    end
  ensure
    ENV.delete("SECRETS_INTERP_TEST_VAR")
  end

  test "resolve uses the default when the variable is missing" do
    ENV.delete("SECRETS_INTERP_MISSING")
    assert_equal "fallback", @interpolator.resolve("${SECRETS_INTERP_MISSING:-fallback}")
  end

  test "resolve raises MissingVariableError when required and absent" do
    ENV.delete("SECRETS_INTERP_MISSING")
    error = assert_raises(SecretsInterpolator::MissingVariableError) do
      @interpolator.resolve("${SECRETS_INTERP_MISSING}")
    end
    assert_match(/SECRETS_INTERP_MISSING/, error.message)
  end

  test "resolve passes through strings without interpolation patterns" do
    assert_equal "plain string", @interpolator.resolve("plain string")
    assert_nil @interpolator.resolve(nil)
  end

  test "resolve_hash_values! resolves and drops blank-with-no-default keys" do
    ENV["SECRETS_INTERP_PRESENT"] = "yes"
    ENV.delete("SECRETS_INTERP_BLANK")
    hash = {
      "PRESENT" => "${SECRETS_INTERP_PRESENT}",
      "BLANK" => "${SECRETS_INTERP_BLANK:-}",
      "EMPTY" => "",
      "LITERAL" => "literal"
    }
    @interpolator.resolve_hash_values!(hash)

    assert_equal "yes", hash["PRESENT"]
    assert_equal "", hash["EMPTY"], "an explicit empty string is preserved"
    assert_equal "literal", hash["LITERAL"]
    refute hash.key?("BLANK"), "a key that resolves to blank with no real value is dropped"
  end

  test "resolve_entry! resolves env, headers, args, and url" do
    ENV["SECRETS_INTERP_TOK"] = "tok123"
    entry = {
      "command" => "npx",
      "args" => [ "-y", "pkg", "--token=${SECRETS_INTERP_TOK}", 42 ],
      "env" => { "API_KEY" => "${SECRETS_INTERP_TOK}" },
      "headers" => { "Authorization" => "Bearer ${SECRETS_INTERP_TOK}" },
      "url" => "https://example.com/${SECRETS_INTERP_TOK}"
    }
    @interpolator.resolve_entry!(entry)

    assert_equal "tok123", entry.dig("env", "API_KEY")
    assert_equal "Bearer tok123", entry.dig("headers", "Authorization")
    assert_equal [ "-y", "pkg", "--token=tok123", 42 ], entry["args"]
    assert_equal "https://example.com/tok123", entry["url"]
  ensure
    ENV.delete("SECRETS_INTERP_TOK")
  end

  test "get_env_value returns nil when neither SecretsLoader nor ENV has the var" do
    ENV.delete("SECRETS_INTERP_NONE")
    assert_nil @interpolator.get_env_value("SECRETS_INTERP_NONE")
  end

  # --- X (Twitter) dynamic token vending (session-prep injection) ---

  test "resolves ${X_OAUTH_ACCESS_TOKEN} to the freshest token from the X credential store" do
    XOauthCredential.create!(
      account_key: "tadasayy",
      access_token_env_var: "X_OAUTH_ACCESS_TOKEN",
      access_token: "live-x-access-token",
      refresh_token: "r",
      expires_at: 1.hour.from_now,
      token_endpoint: XOauthCredential::DEFAULT_TOKEN_ENDPOINT
    )

    # This is the exact shape the x-twitter catalog entry will have — proving
    # session-prep injects a valid access token into the generated .mcp.json env.
    entry = {
      "command" => "npx",
      "args" => [ "-y", "x-twitter-mcp-server@latest" ],
      "env" => {
        "X_OAUTH_ACCESS_TOKEN" => "${X_OAUTH_ACCESS_TOKEN}",
        "X_TWITTER_ENABLED_TOOLGROUPS" => "readonly,readwrite"
      }
    }
    @interpolator.resolve_entry!(entry)

    assert_equal "live-x-access-token", entry.dig("env", "X_OAUTH_ACCESS_TOKEN")
    assert_equal "readonly,readwrite", entry.dig("env", "X_TWITTER_ENABLED_TOOLGROUPS")
  end

  test "the X token vendor takes priority over SecretsLoader for its variable" do
    XOauthCredential.create!(
      account_key: "tadasayy", access_token_env_var: "X_OAUTH_ACCESS_TOKEN",
      access_token: "from-store", refresh_token: "r", expires_at: 1.hour.from_now,
      token_endpoint: XOauthCredential::DEFAULT_TOKEN_ENDPOINT
    )
    SecretsLoader.stub(:exists?, ->(name) { name == "X_OAUTH_ACCESS_TOKEN" }) do
      SecretsLoader.stub(:get, ->(_) { "stale-credentials-value" }) do
        assert_equal "from-store", @interpolator.get_env_value("X_OAUTH_ACCESS_TOKEN")
      end
    end
  end
end
