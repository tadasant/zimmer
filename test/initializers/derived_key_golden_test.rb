# frozen_string_literal: true

require "test_helper"
require "open3"

# What Zimmer derives from SECRET_KEY_BASE must not change under a deploy: web sign-in
# cookies, elicitation URLs already handed to running agents, stored webhook secrets,
# queued turn-source notes, stream names held by open tabs.
#
# A test that mints and reads in one tree cannot see such a change, because a tree
# always agrees with itself. So these values are CONSTANTS, minted by `main` at
# 6c7db244 in production mode with the key below, and the current tree has to read
# them. The fault this was written for asked Rails.application.key_generator for a key
# during boot, which froze its digest at SHA1 (config/initializers/
# active_record_encryption.rb); every other test passed.
#
# If one of these fails, the deploy would break that value for everyone. Do not update
# a constant to make it pass unless rotating it is the point, and then say so.
#
# The key is a test constant and protects nothing.
class DerivedKeyGoldenTest < ActiveSupport::TestCase
  SECRET = "golden" * 12

  DIGEST = "OpenSSL::Digest::SHA256"
  DERIVED_KEY = "97c89dad7baaa958c36a34a265247455b5de8434c7c475acd32f287f8ca7f179"

  GOLDEN = {
    "verifier" => "ImdvbGRlbiI=--c69d9430fd0872498ea7013a4490e51e55a226f0",
    "cookie" => "P80JMW77fLfxvryoxTZdRt/P8eXU2b5wjY0gEHyNETmP5tipSdZQsCSRrUW2uWudbbxNQxFgI6v84bD/cqDPQeH5SC/6Hw==--sA5g1uYAPN2wI4HX--9ZJ97zKa0BD1aTJZoQ1ZVA==",
    "signed_cookie" => "eyJfcmFpbHMiOnsibWVzc2FnZSI6IkltZHZiR1JsYmlJPSIsImV4cCI6bnVsbCwicHVyIjoiY29va2llLmdvbGRlbiJ9fQ==--88d213f2fba5ea44d4ab43d620c04590cab42859",
    "elicitation" => "5-3avqO1eK34lYgD1McLpid11vTadI3HYbvwO4611X1yc",
    "webhook" => "vdkVf+RbFho=--WkLd13NL0KEapp79--7VF2+MWcJBgXXJyOU90KNQ==",
    "turn_note" => "golden body\n\n<zimmer-turn-source surface=\"web\" modality=\"text\" sig=\"952afdaa5aa97950c764ba6430dff0fa\">Sent from the Zimmer web app · typed — full markdown is fine.</zimmer-turn-source>",
    "turbo_stream" => "ImdvbGRlbiI=--ec827da111805229d6e608426fb245b3a03b2a68e1ca3b10e82458bb3ed268af",
    "sgid" => "ImdvbGRlbiI=--1e99566d3901349d655a7a20c160bfa37f29eb31",
    "delegation" => "eyJfcmFpbHMiOnsiZGF0YSI6eyJjIjoxLCJkIjoieCJ9LCJwdXIiOiJsaXZlX2RlbGVnYXRpb25fbWNwIn19--060fae4f8cad5b07adcd9e8f687946780a0aacf0"
  }.freeze

  # Boots like ProductionBootTest: production, its initializers in full, no eager load
  # and no database.
  PROBE = <<~'RUBY'
    require "./config/application"
    Rails.application.class.initializer("boot_probe_skip_eager_load", before: :eager_load!) { |app| app.config.eager_load = false }
    Rails.application.initialize!
    g = JSON.parse(ENV.fetch("GOLDEN_JSON"))
    generator = Rails.application.key_generator
    # Rails binds a cookie to its name, so each is read back as "golden".
    jar = lambda do |value|
      ActionDispatch::Request.new(Rails.application.env_config.merge(Rack::MockRequest.env_for("https://zimmer.example.test/"))).cookie_jar.tap { |j| j.update("golden" => value) }
    end
    verifier = ->(name, token, **o) { Rails.application.message_verifier(name).verified(token, **o) }
    purpose = LiveConversations::DelegationToken::PURPOSE
    out = {
      "digest" => generator.instance_variable_get(:@key_generator).instance_variable_get(:@hash_digest_class).name,
      "derived_key" => generator.generate_key("golden", 32).unpack1("H*"),
      "verifier" => Rails.application.message_verifier("golden").generate("golden") == g["verifier"],
      "cookie" => jar.(g["cookie"]).encrypted[:golden] == "golden",
      "signed_cookie" => jar.(g["signed_cookie"]).signed[:golden] == "golden",
      "elicitation" => ElicitationEndpoint.token_for(5) == g["elicitation"],
      "webhook" => (ActiveSupport::MessageEncryptor.new(generator.generate_key("zimmer-mcp-events-webhook-secret-v1", ActiveSupport::MessageEncryptor.key_len)).decrypt_and_verify(g["webhook"]) == "golden" rescue false),
      "turn_note" => TurnSource.finalize(g["turn_note"]) == g["turn_note"],
      "turbo_stream" => Turbo.signed_stream_verifier.verified(g["turbo_stream"]) == "golden",
      "sgid" => SignedGlobalID.verifier.verified(g["sgid"]) == "golden",
      "delegation" => verifier.(purpose, g["delegation"], purpose: purpose) == { "c" => 1, "d" => "x" }
    }
    puts "GOLDEN_RESULT=#{JSON.generate(out)}"
  RUBY

  def self.result
    @result ||= begin
      env = {
        "RAILS_ENV" => "production", "SECRET_KEY_BASE" => SECRET, "GOLDEN_JSON" => JSON.generate(GOLDEN),
        "DATABASE_URL" => nil, "REDIS_URL" => "redis://127.0.0.1:1", "AIR_CONFIG" => nil, "RAILS_MASTER_KEY" => nil,
        "SENTRY_DSN_BACKEND" => nil, "OTEL_LOGS_EXPORTER_ENDPOINT" => nil, "OTEL_LOGS_EXPORTER_BEARER_TOKEN" => nil,
        "GOOD_JOB_EXECUTION_MODE" => "external", "DATABASE_HOST" => "127.0.0.1", "DATABASE_PORT" => "1", "DATABASE_SSLMODE" => "disable",
        "APP_HOST" => nil, "ZIMMER_PROD_BASE_URL" => "https://zimmer.example.test", "ZIMMER_TOKEN_BROKER_ENABLED" => nil,
        OauthClientIdentity::BASE_URL_ENV => nil, "PARALLEL_WORKERS" => nil
      }
      output, = Timeout.timeout(120) { Open3.capture2e(env, RbConfig.ruby, "-e", PROBE, chdir: Rails.root.to_s) }
      line = output.lines.reverse.find { |l| l.include?("GOLDEN_RESULT=") }
      raise "the boot probe printed no result:\n#{output.lines.last(15).join}" unless line

      JSON.parse(line.split("GOLDEN_RESULT=", 2).last)
    end
  end

  test "the application's key generator derives exactly what main's does" do
    assert_equal DIGEST, self.class.result["digest"]
    assert_equal DERIVED_KEY, self.class.result["derived_key"]
  end

  GOLDEN.each_key do |name|
    test "a #{name} value minted by main is still good" do
      assert self.class.result.fetch(name), "every #{name} value issued before this deploy would stop working"
    end
  end
end
