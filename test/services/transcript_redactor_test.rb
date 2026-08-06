# frozen_string_literal: true

require "test_helper"

class TranscriptRedactorTest < ActiveSupport::TestCase
  setup do
    TranscriptRedactor.reset_known_secrets!
  end

  teardown do
    TranscriptRedactor.reset_known_secrets!
  end

  # --- Credential shapes this system actually handles -----------------------

  # Each entry is [label, a sample of the shape, the redaction label expected].
  # The samples are synthetic but structurally faithful; none is a live value.
  SHAPES = {
    "Anthropic OAuth access token" => [
      "sk-ant-oat01-#{'A1b2C3d4E5' * 4}",
      "ANTHROPIC_OAUTH_TOKEN"
    ],
    "Anthropic OAuth refresh token" => [
      "sk-ant-ort01-#{'Z9y8X7w6V5' * 4}",
      "ANTHROPIC_OAUTH_TOKEN"
    ],
    "Anthropic API key" => [
      "sk-ant-api03-#{'Qq1Ww2Ee3R' * 5}",
      "ANTHROPIC_API_KEY"
    ],
    "OpenAI project key" => [
      "sk-proj-#{'aB3dE6gH9j' * 4}",
      "OPENAI_API_KEY"
    ],
    "GitHub personal access token" => [
      "ghp_#{'a1B2c3D4e5' * 4}",
      "GITHUB_TOKEN"
    ],
    "GitHub fine-grained token" => [
      "github_pat_#{'11ABCDEFG0' * 3}",
      "GITHUB_TOKEN"
    ],
    "Slack bot token" => [
      "xoxb-1234567890-1234567890123-#{'AbCdEfGhIj' * 2}",
      "SLACK_TOKEN"
    ],
    "Slack app-level token" => [
      "xapp-1-A012BCDEFGH-1234567890123-#{'0a1b2c3d4e' * 2}",
      "SLACK_APP_TOKEN"
    ],
    "Google API key" => [
      "AIza#{'Sy0aBcDeFg' * 3}HiJkL",
      "GOOGLE_API_KEY"
    ],
    "AWS access key id" => [
      "AKIAIOSFODNN7EXAMPLE",
      "AWS_ACCESS_KEY_ID"
    ],
    "npm token" => [
      "npm_#{'aBcDeFgHiJ' * 4}",
      "NPM_TOKEN"
    ],
    "1Password service account token" => [
      "ops_#{'eyJzaWduSW' * 6}",
      "OP_SERVICE_ACCOUNT_TOKEN"
    ],
    "Stripe key" => [
      "sk_live_#{'4eC39HqLyj' * 3}",
      "STRIPE_KEY"
    ],
    "JWT" => [
      "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk",
      "JWT"
    ]
  }.freeze

  SHAPES.each do |description, (sample, label)|
    test "redacts a #{description}" do
      line = %({"type":"user","content":"the value is #{sample}"})

      redacted = TranscriptRedactor.redact(line)

      assert_includes redacted, "[REDACTED:#{label}]", "expected a #{label} redaction in: #{redacted}"
      refute_includes redacted, sample
    end

    test "leaves nothing reversible behind for a #{description}" do
      redacted = TranscriptRedactor.redact("value: #{sample}")

      # No run of the original long enough to be useful may survive. 8 is well
      # under any real credential's entropy floor and well over the length of
      # the structural prefixes ("sk-", "ghp_") a reader needs to see.
      leaked = sample.chars.each_cons(8).map(&:join).select { |chunk| redacted.include?(chunk) }
      assert_empty leaked, "redacted output still contains fragments of the secret: #{leaked.first(3)}"
    end
  end

  test "redacts a bearer token but keeps the header readable" do
    redacted = TranscriptRedactor.redact(%(-H "Authorization: Bearer abcdef0123456789abcdef0123456789"))

    assert_includes redacted, "Authorization: Bearer [REDACTED:BEARER_TOKEN]"
    refute_includes redacted, "abcdef0123456789"
  end

  test "redacts an AWS secret access key" do
    redacted = TranscriptRedactor.redact(%(aws_secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"))

    assert_includes redacted, "[REDACTED:AWS_SECRET_ACCESS_KEY]"
    refute_includes redacted, "wJalrXUtnFEMI/K7MDENG"
  end

  test "redacts an X-API-Key header value" do
    redacted = TranscriptRedactor.redact(%({"X-API-Key": "zk_live_9f8e7d6c5b4a39281706"}))

    assert_includes redacted, "[REDACTED:API_KEY_HEADER]"
    refute_includes redacted, "9f8e7d6c5b4a39281706"
  end

  test "redacts an Authorization Basic value but not the word basic elsewhere" do
    redacted = TranscriptRedactor.redact(%(-H "Authorization: Basic dXNlcjpwYXNzd29yZDEyMzQ1Ng=="))

    assert_includes redacted, "Basic [REDACTED:BASIC_AUTH]"
    refute_includes redacted, "dXNlcjpwYXNzd29yZDEyMzQ1Ng"
  end

  test "redacts a token in the userinfo-only form of a git remote" do
    token = "ghs_abcdefghijklmnopqrstuvwxyz012345"
    redacted = TranscriptRedactor.redact("https://#{token}@github.com/tadasant/zimmer.git")

    refute_includes redacted, token
    assert_includes redacted, "@github.com/tadasant/zimmer.git"
  end

  test "redacts credentials embedded in an authenticated git remote" do
    redacted = TranscriptRedactor.redact("https://x-access-token:ghs_abcdefghijklmnop@github.com/tadasant/zimmer.git")

    refute_includes redacted, "ghs_abcdefghijklmnop"
    assert_includes redacted, "github.com/tadasant/zimmer.git", "the host and repo must survive for debugging"
  end

  test "redacts a database password but keeps scheme, user and host" do
    redacted = TranscriptRedactor.redact("postgres://zimmer:s3cr3t-p4ssw0rd@db.internal:5432/zimmer_production")

    refute_includes redacted, "s3cr3t-p4ssw0rd"
    assert_includes redacted, "postgres://zimmer:"
    assert_includes redacted, "@db.internal:5432/zimmer_production"
  end

  test "redacts a named secret value while keeping the name" do
    redacted = TranscriptRedactor.redact(%(RAILS_MASTER_KEY=0123456789abcdef0123456789abcdef))

    assert_includes redacted, "RAILS_MASTER_KEY=[REDACTED:ENV_SECRET]"
  end

  test "redacts a PEM private key escaped inside a JSON string" do
    line = %({"private_key":"-----BEGIN PRIVATE KEY-----\\nMIIEvQIBADANBgkqhkiG9w0BAQ\\n-----END PRIVATE KEY-----\\n"})

    redacted = TranscriptRedactor.redact(line)

    assert_includes redacted, "[REDACTED:"
    refute_includes redacted, "MIIEvQIBADANBgkqhkiG9w0BAQ"
  end

  test "redacts a real multi-line PEM block without changing the line count" do
    content = <<~TEXT
      $ cat ~/.ssh/id_rsa
      -----BEGIN OPENSSH PRIVATE KEY-----
      b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABlwAAAAdzc2gt
      cnNhAAAAAwEAAQAAAYEAwvUwGkPtHkKGZ7YnQqEXAMPLEEXAMPLEEXAMPLEEXAMPLE
      -----END OPENSSH PRIVATE KEY-----
      $ echo done
    TEXT

    redacted = TranscriptRedactor.redact(content)

    assert_equal content.lines.length, redacted.lines.length
    refute_includes redacted, "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ"
    assert_includes redacted, "$ cat ~/.ssh/id_rsa"
    assert_includes redacted, "$ echo done"
    assert_equal 4, redacted.lines.count { |line| line.start_with?("[REDACTED:PRIVATE_KEY]") }
  end

  test "an unclosed BEGIN marker in prose does not swallow the rest of the transcript" do
    content = <<~TEXT
      The file should start with -----BEGIN PRIVATE KEY----- and then the body.
      Here is the next thing I did, which must survive.
      And another line of ordinary output.
    TEXT

    redacted = TranscriptRedactor.redact(content)

    assert_includes redacted, "Here is the next thing I did, which must survive."
    assert_includes redacted, "And another line of ordinary output."
  end

  # --- Ordinary transcript content must survive intact ----------------------

  ORDINARY = [
    %({"type":"assistant","message":{"content":[{"type":"text","text":"I'll update the README next."}]}}),
    %({"type":"tool_use","id":"toolu_01A09q90qw90lq917835lq9","name":"Read","input":{"file_path":"/app/models/session.rb"}}),
    %(  const apiKey = process.env.ANTHROPIC_API_KEY;),
    %(export ANTHROPIC_API_KEY=$SOME_OTHER_VAR),
    %(commit 98fdded1c2b3a4e5f60718293a4b5c6d7e8f9012 (HEAD -> main)),
    %(  Failures: 0, Errors: 0, Skips: 3 — finished in 41.882714s),
    %(diff --git a/app/services/open_transcript.rb b/app/services/open_transcript.rb),
    %(See https://docs.zimmer.tadasant.com/sessions/transcripts/ for the pipeline diagram.),
    %(The password field should be validated for presence before save.),
    # Hyphenated prose containing "risk-": the `sk-` key patterns must not fire
    # mid-token. Without a left boundary these redact to "ri[REDACTED:…]".
    %(we discussed risk-assessment-frameworks and risk-management-and-oversight),
    %(  modified:   docs/risk-mitigation-strategy-notes.md),
    %(task-sk-something-else-entirely-here),
    # "basic" is an English word and its value class must include `/` for base64,
    # so the Basic-auth rule has to be anchored on the Authorization header.
    %(basic app/models/session works, as does the basic authentication/authorization flow),
    # A URL with an ordinary username and no credential must survive.
    %(git remote add origin https://tadasant@github.com/tadasant/zimmer.git)
  ].freeze

  ORDINARY.each_with_index do |line, index|
    test "leaves ordinary transcript content ##{index} untouched" do
      # Stubbed empty so this asserts only what the shape patterns do. Otherwise
      # the assertion silently depends on fixture credential values
      # (claude_accounts.yml) not colliding with the sample text.
      TranscriptRedactor.stub(:known_secrets, []) do
        assert_equal line, TranscriptRedactor.redact(line)
      end
    end
  end

  test "leaves a whole ordinary transcript byte-identical" do
    content = ORDINARY.join("\n") + "\n"

    TranscriptRedactor.stub(:known_secrets, []) do
      assert_equal content, TranscriptRedactor.redact(content)
    end
  end

  # --- Structural invariants the transcript pipeline depends on -------------

  test "preserves line count and the trailing-newline property" do
    with_newline = "a\nsk-ant-oat01-#{'A1b2C3d4E5' * 4}\nb\n"
    without_newline = "a\nsk-ant-oat01-#{'A1b2C3d4E5' * 4}\nb"

    assert_equal 3, TranscriptRedactor.redact(with_newline).lines.length
    assert TranscriptRedactor.redact(with_newline).end_with?("\n")

    assert_equal 3, TranscriptRedactor.redact(without_newline).lines.length
    refute TranscriptRedactor.redact(without_newline).end_with?("\n")
  end

  test "keeps every redacted line valid JSON" do
    line = %({"type":"user","content":"key sk-ant-api03-#{'Qq1Ww2Ee3R' * 5} here"})

    parsed = JSON.parse(TranscriptRedactor.redact(line))

    assert_includes parsed["content"], "[REDACTED:ANTHROPIC_API_KEY]"
  end

  test "is idempotent" do
    content = "token: #{'a1b2c3d4e5' * 4}\nBearer #{'f6g7h8i9j0' * 4}\n"

    once = TranscriptRedactor.redact(content)

    assert_equal once, TranscriptRedactor.redact(once)
  end

  test "passes nil and empty content through" do
    assert_nil TranscriptRedactor.redact(nil)
    assert_equal "", TranscriptRedactor.redact("")
  end

  test "survives invalid UTF-8 without raising" do
    content = "ok\n\xC3\x28 sk-ant-oat01-#{'A1b2C3d4E5' * 4}\n".dup.force_encoding("UTF-8")

    redacted = TranscriptRedactor.redact(content)

    assert_includes redacted, "[REDACTED:ANTHROPIC_OAUTH_TOKEN]"
  end

  # --- Known-value redaction ------------------------------------------------

  test "redacts an exact known secret value with no recognizable shape" do
    value = "zmr-8f3a91b0c7d24e65"
    TranscriptRedactor.stub(:known_secrets, [ [ value, "ENV:STRAD_API_KEY" ] ]) do
      redacted = TranscriptRedactor.redact(%(curl -H "X-Custom: #{value}" https://strad.example.com))

      assert_includes redacted, "[REDACTED:ENV:STRAD_API_KEY]"
      refute_includes redacted, value
    end
  end

  test "redacts the longest known value first when one contains another" do
    known = [ [ "abcdefghijkl-mnopqrstuvwx", "ENV:LONG" ], [ "abcdefghijkl", "ENV:SHORT" ] ]

    TranscriptRedactor.stub(:known_secrets, known) do
      assert_equal "[REDACTED:ENV:LONG]", TranscriptRedactor.redact("abcdefghijkl-mnopqrstuvwx")
    end
  end

  test "known secrets resolve from the catalog's MCP variables" do
    server = ServersConfig::Server.new("fake", { "type" => "stdio", "env" => { "TOKEN" => "${FAKE_SECRET_VAR}" } })

    ServersConfig.stub(:all, [ server ]) do
      SecretProviders.chain.stub(:get, ->(name) { name == "FAKE_SECRET_VAR" ? "s3cret-value-not-a-shape" : nil }) do
        TranscriptRedactor.reset_known_secrets!

        assert_includes TranscriptRedactor.known_secrets, [ "s3cret-value-not-a-shape", "ENV:FAKE_SECRET_VAR" ]
      end
    end
  end

  test "known secrets skip values too short or too ambiguous to redact safely" do
    server = ServersConfig::Server.new("fake", {
      "type" => "stdio",
      "env" => { "A" => "${SHORT_VAR}", "B" => "${BOOL_VAR}", "C" => "${SPACED_VAR}" }
    })
    values = { "SHORT_VAR" => "abc123", "BOOL_VAR" => "true", "SPACED_VAR" => "not a secret at all" }

    ServersConfig.stub(:all, [ server ]) do
      SecretProviders.chain.stub(:get, ->(name) { values[name] }) do
        TranscriptRedactor.reset_known_secrets!

        assert_empty TranscriptRedactor.known_secrets.map(&:first) & values.values
      end
    end
  end

  test "known secrets include OAuth tokens Zimmer stores itself" do
    ClaudeAccount.create!(
      email: "redaction-test@example.com",
      runtime: "claude_code",
      oauth_config: {
        "credentials_json" => {
          "claudeAiOauth" => {
            "accessToken" => "opaque-access-token-value-0001",
            "refreshToken" => "opaque-refresh-token-value-0002",
            "subscriptionType" => "redaction-test-subscription-tier"
          }
        }
      }
    )

    TranscriptRedactor.reset_known_secrets!
    values = TranscriptRedactor.known_secrets.map(&:first)

    assert_includes values, "opaque-access-token-value-0001"
    assert_includes values, "opaque-refresh-token-value-0002"
    refute_includes values, "redaction-test-subscription-tier",
      "a field whose key does not name a credential must not be pulled into the table"
  end

  test "a failing secret source degrades to shape patterns instead of raising" do
    ServersConfig.stub(:all, ->(*) { raise ParameterStore::StoreError.new("store unreachable", 503) }) do
      TranscriptRedactor.reset_known_secrets!

      redacted = TranscriptRedactor.redact("sk-ant-oat01-#{'A1b2C3d4E5' * 4}")

      assert_includes redacted, "[REDACTED:ANTHROPIC_OAUTH_TOKEN]"
    end
  end
end
