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
    "Zimmer minted API key" => [
      "zmr_#{'0123456789abcdef' * 4}",
      "ZIMMER_API_KEY"
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

      assert_includes redacted, "[REDACTED:MATCH:#{label}:", "expected a #{label} redaction in: #{redacted}"
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

    assert_includes redacted, "Authorization: Bearer [REDACTED:MATCH:BEARER_TOKEN:32ch]"
    refute_includes redacted, "abcdef0123456789"
  end

  test "redacts an AWS secret access key" do
    redacted = TranscriptRedactor.redact(%(aws_secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"))

    assert_includes redacted, "[REDACTED:MATCH:AWS_SECRET_ACCESS_KEY:40ch]"
    refute_includes redacted, "wJalrXUtnFEMI/K7MDENG"
  end

  test "redacts an X-API-Key header value" do
    redacted = TranscriptRedactor.redact(%({"X-API-Key": "zk_live_9f8e7d6c5b4a39281706"}))

    assert_includes redacted, "[REDACTED:MATCH:API_KEY_HEADER:"
    refute_includes redacted, "9f8e7d6c5b4a39281706"
  end

  test "redacts an Authorization Basic value but not the word basic elsewhere" do
    redacted = TranscriptRedactor.redact(%(-H "Authorization: Basic dXNlcjpwYXNzd29yZDEyMzQ1Ng=="))

    assert_includes redacted, "Basic [REDACTED:MATCH:BASIC_AUTH:"
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

    assert_includes redacted, "RAILS_MASTER_KEY=[REDACTED:MATCH:ENV_SECRET:32ch]"
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
    assert_equal 4, redacted.lines.count { |line| line.start_with?("[REDACTED:MATCH:PRIVATE_KEY:") }
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

  # --- Resource names are not credentials ------------------------------------

  # The literal string and the literal command line from the incident. An
  # orchestrator session handed a human this command to run and the redactor
  # blanked the `--secret=` argument, so the instruction identified no secret
  # and the human could not run it. The value is the NAME of a Secret Manager
  # secret — what `gcloud secrets list` prints to anyone with read access on the
  # project. The credential is the version's payload, which was never in the
  # message.
  SECRET_RESOURCE_NAME = "strad-prod-mcp-google-sheets-tadas412-ro-static-google-ada4ec8f"
  GCLOUD_ACCESS_COMMAND = <<~COMMAND
    gcloud secrets versions access latest --project=strad-secrets-prod \\
      --secret=#{SECRET_RESOURCE_NAME}
  COMMAND

  test "leaves a Secret Manager resource name in a gcloud command runnable" do
    TranscriptRedactor.stub(:known_secrets, []) do
      assert_equal GCLOUD_ACCESS_COMMAND, TranscriptRedactor.redact(GCLOUD_ACCESS_COMMAND)
    end
  end

  # The nouns the cloud CLIs use for the resource, in the framings they actually
  # appear in. Every value here is an identifier a `list` call hands out.
  # Every entry must be one the rule WOULD match — a credential noun followed
  # immediately by `:` or `=` and a long enough value. A framing with a space
  # after the noun (`kubectl create secret generic NAME`) never reached the rule
  # in the first place and would pass with the whole guard deleted.
  PUBLIC_IDENTIFIERS = [
    %(gcloud secrets versions access latest --secret=strad-prod-mcp-google-sheets-tadas412-ro),
    %(--secret=projects/strad-secrets-prod/secrets/google-sheets-ro/versions/latest),
    %(https://console.cloud.google.com/security/secret-manager?secret=strad-prod-mcp-google-sheets),
    %(vault kv get -format=json secret=strad-prod-google-sheets-ro),
    %(  secret: zimmer-production-tls-certificate),
    %({"token": "github-actions-deploy-workflow"})
  ].freeze

  PUBLIC_IDENTIFIERS.each_with_index do |line, index|
    test "leaves public identifier ##{index} untouched" do
      TranscriptRedactor.stub(:known_secrets, []) do
        assert_equal line, TranscriptRedactor.redact(line)
      end
    end
  end

  # The counterweight. Narrowing the two ambiguous nouns must not open a hole in
  # any of these, and the second half of the list is deliberately adversarial:
  # values that are lowercase and hyphenated, like an identifier, but are real
  # credential formats.
  # Each entry under "isolates" fails exactly ONE condition of
  # `public_identifier?` and satisfies every other, so deleting that condition
  # makes the case leak. A fixture that fails two conditions proves nothing
  # about either.
  STILL_REDACTED = {
    "an opaque value after a bare SECRET=" => "SECRET=aB3xK9mQ2pL7vR4tY8nW",
    "a hex value after a bare secret=" => "secret=0123456789abcdef0123456789abcdef",
    "a value noun is never excused: client_secret" => %({"client_secret": "configured-client-secret"}),
    "a value noun is never excused: password" => "password=correct-horse-battery-staple",
    "a value noun is never excused: api_key" => "api_key: my-team-service-account",
    # A compound ENDING in a bare noun is a value noun too. `preceded_by` is
    # unanchored on the left, so its match on `GITHUB_TOKEN` starts at `TOKEN`;
    # judging that tail alone would excuse every one of these.
    "a compound ending in token: GITHUB_TOKEN" => "GITHUB_TOKEN=my-github-deploy-token-value",
    "a compound ending in secret: WEBHOOK_SECRET" => "WEBHOOK_SECRET=tinsel-baffle-unroll-frisky",
    "a compound ending in secret: JWT_SECRET" => "JWT_SECRET=change-me-in-production-now",
    "a compound ending in secret: SLACK_SIGNING_SECRET" => "SLACK_SIGNING_SECRET=abc-def-ghi-jkl-mno-pqr",
    "a compound ending in token: api_token" => "api_token=my-service-account-token",
    "a camelCase compound: apiToken" => %({"apiToken": "my-service-account-token"}),
    # Isolates the wordiness condition: lowercase, 5 segments, all short.
    "isolates wordiness: a UUID session token" => "token=550e8400-e29b-41d4-a716-446655440000",
    "isolates wordiness: a hyphen-grouped hex key" => "secret=deadbeef-cafe-f00d-babe-0ff1ce5deadbe",
    # Isolates the lowercase condition: 4 segments, all short, all wordy.
    "isolates case: an uppercase segment" => "secret=Prod-Api-Key-Store",
    # Isolates the three-segment floor: lowercase, short, wordy.
    "isolates the segment floor: two segments" => "secret=alphabet-charlies",
    # Isolates MAX_SEGMENT: lowercase, 3 segments, wordy, one segment over 12.
    "isolates max segment: a long opaque tail" => "secret=prod-api-abcdefghijklmnopqrst"
  }.freeze

  STILL_REDACTED.each do |description, line|
    test "still redacts #{description}" do
      TranscriptRedactor.stub(:known_secrets, []) do
        redacted = TranscriptRedactor.redact(line)

        assert_includes redacted, "[REDACTED:MATCH:", "expected a redaction in: #{redacted}"
        assert_equal line.split(/[:=]/, 2).first, redacted.split(/[:=]/, 2).first,
          "the name must survive so the redaction stays readable"
      end
    end
  end

  # The shape test is never handed a long string, because the transcript this
  # file is otherwise built around can put megabytes after a `token=`. The
  # segment repeated here ("prod") satisfies every OTHER condition, so these two
  # isolate the length cap rather than passing for an unrelated reason.
  test "an over-long identifier-shaped value is still redacted rather than scanned" do
    oversized = ([ "prod" ] * 80).join("-")
    assert_operator oversized.length, :>, TranscriptRedactor::PUBLIC_IDENTIFIER_MAX_LENGTH

    TranscriptRedactor.stub(:known_secrets, []) do
      assert_includes TranscriptRedactor.redact("token=#{oversized}"), "[REDACTED:MATCH:ENV_SECRET:"
    end
  end

  test "the same value under the cap is recognized as an identifier" do
    under = ([ "prod" ] * 51).join("-")
    assert_operator under.length, :<=, TranscriptRedactor::PUBLIC_IDENTIFIER_MAX_LENGTH
    line = "token=#{under}"

    TranscriptRedactor.stub(:known_secrets, []) do
      assert_equal line, TranscriptRedactor.redact(line)
    end
  end

  # --- A marker a human can act on ------------------------------------------

  # The incident's second half: `[REDACTED:ENV_SECRET]` named an internal rule
  # and said nothing about what was removed, so a reader could not tell a
  # confirmed credential from a guess. The tier has to be legible from the
  # marker alone.
  test "an exact known value is marked with the variable it was" do
    TranscriptRedactor.stub(:known_secrets, [ [ "zmr-8f3a91b0c7d24e65", "ENV:STRAD_API_KEY" ] ]) do
      assert_equal "[REDACTED:ENV:STRAD_API_KEY:20ch]", TranscriptRedactor.redact("zmr-8f3a91b0c7d24e65")
    end
  end

  test "a shape match is marked as a match rather than as a confirmed credential" do
    TranscriptRedactor.stub(:known_secrets, []) do
      redacted = TranscriptRedactor.redact("ghp_#{'a1B2c3D4e5' * 4}")

      assert_equal "[REDACTED:MATCH:GITHUB_TOKEN:44ch]", redacted
    end
  end

  test "every marker carries the length of what it stood in for" do
    TranscriptRedactor.stub(:known_secrets, []) do
      redacted = TranscriptRedactor.redact("SECRET=aB3xK9mQ2pL7vR4tY8nW")

      assert_equal "SECRET=[REDACTED:MATCH:ENV_SECRET:20ch]", redacted
    end
  end

  # A marker that still looked like a credential to a later pattern would be
  # re-redacted on the next poll, and the transcript would drift on every pass.
  test "a marker is not itself redactable" do
    TranscriptRedactor.stub(:known_secrets, []) do
      once = TranscriptRedactor.redact("SECRET=aB3xK9mQ2pL7vR4tY8nW
token=#{'Zz9' * 12}
")

      assert_equal once, TranscriptRedactor.redact(once)
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

    assert_includes parsed["content"], "[REDACTED:MATCH:ANTHROPIC_API_KEY:"
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

    assert_includes redacted, "[REDACTED:MATCH:ANTHROPIC_OAUTH_TOKEN:"
  end

  # --- Known-value redaction ------------------------------------------------

  test "redacts an exact known secret value with no recognizable shape" do
    value = "zmr-8f3a91b0c7d24e65"
    TranscriptRedactor.stub(:known_secrets, [ [ value, "ENV:STRAD_API_KEY" ] ]) do
      redacted = TranscriptRedactor.redact(%(curl -H "X-Custom: #{value}" https://strad.example.com))

      assert_includes redacted, "[REDACTED:ENV:STRAD_API_KEY:20ch]"
      refute_includes redacted, value
    end
  end

  test "redacts the longest known value first when one contains another" do
    known = [ [ "abcdefghijkl-mnopqrstuvwx", "ENV:LONG" ], [ "abcdefghijkl", "ENV:SHORT" ] ]

    TranscriptRedactor.stub(:known_secrets, known) do
      assert_equal "[REDACTED:ENV:LONG:25ch]", TranscriptRedactor.redact("abcdefghijkl-mnopqrstuvwx")
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

      assert_includes redacted, "[REDACTED:MATCH:ANTHROPIC_OAUTH_TOKEN:"
    end
  end

  # --- The global regexp cap must not be able to abort a scan ---------------
  #
  # Rails 8 sets `Regexp.timeout = 1` process-wide. A transcript is megabytes, so
  # a single search reaches that cap on a large enough one — measured on a real
  # 32 MB transcript, DB_CONNECTION_STRING's gap scan raised at exactly 1.000 s
  # and ENV_SECRET's 3.5 MB match at 2.2 s. The error escaped
  # `TranscriptSource#read` into the poller, which dropped the whole transcript
  # update and paged `#alerts` (#472).
  #
  # These tests shrink the cap instead of growing the fixture: the failure mode
  # is "the global cap aborts the scan", and a 1 ms cap over a small transcript
  # exercises it exactly, in milliseconds rather than by materializing tens of
  # megabytes in CI.

  # Redaction shapes that must survive the whole exercise, in a transcript big
  # enough that every pattern has real text to scan through.
  def transcript_with_credentials(padding_bytes: 512 * 1024)
    filler = %({"type":"assistant","message":{"content":[{"type":"text","text":"#{'ordinary transcript output. ' * 40}"}]}}\n)
    [
      %({"type":"user","content":"key sk-ant-oat01-#{'A1b2C3d4E5' * 4}"}\n),
      filler * (padding_bytes / filler.bytesize),
      %(  remote: https://x-access-token:ghs_abcdefghijklmnop@github.com/tadasant/zimmer.git\n),
      %(  RAILS_MASTER_KEY=0123456789abcdef0123456789abcdef\n),
      %(  -H "Authorization: Bearer abcdef0123456789abcdef0123456789"\n)
    ].join
  end

  def with_regexp_timeout(seconds)
    previous = Regexp.timeout
    Regexp.timeout = seconds
    yield
  ensure
    Regexp.timeout = previous
  end

  test "every pattern carries its own timeout so the global cap cannot abort it" do
    TranscriptRedactor::PATTERNS.each do |pattern|
      assert_equal TranscriptRedactor::SCAN_TIMEOUT, pattern.regexp.timeout,
        "#{pattern.label} is still on the global Regexp.timeout, which a large transcript reaches"
    end

    [ :PRIVATE_KEY_BEGIN, :PRIVATE_KEY_END, :PRIVATE_KEY_BODY_LINE ].each do |name|
      assert_equal TranscriptRedactor::SCAN_TIMEOUT, TranscriptRedactor.const_get(name).timeout,
        "#{name} is matched against a whole transcript or a whole line and must carry its own timeout"
    end
  end

  test "a transcript still redacts when the global regexp cap is far below the cost of scanning it" do
    content = transcript_with_credentials

    redacted = TranscriptRedactor.stub(:known_secrets, []) do
      with_regexp_timeout(0.001) { TranscriptRedactor.redact(content) }
    end

    assert_includes redacted, "[REDACTED:MATCH:ANTHROPIC_OAUTH_TOKEN:"
    assert_includes redacted, "[REDACTED:MATCH:URL_CREDENTIALS:"
    assert_includes redacted, "[REDACTED:MATCH:ENV_SECRET:"
    assert_includes redacted, "[REDACTED:MATCH:BEARER_TOKEN:"
    assert_equal content.lines.length, redacted.lines.length
  end

  # The patterns are off the global cap by construction, so this is really about
  # the `preceded_by` regexps, which are deliberately left on it. They decide
  # whether an ENV_SECRET or BASIC_AUTH candidate is a credential or ordinary
  # prose, so a cap that could abort one would change what is redacted rather
  # than merely raise.
  test "the global cap changes nothing about what is redacted" do
    content = transcript_with_credentials

    TranscriptRedactor.stub(:known_secrets, []) do
      under_production_cap = with_regexp_timeout(1) { TranscriptRedactor.redact(content) }
      under_no_cap = with_regexp_timeout(nil) { TranscriptRedactor.redact(content) }

      assert_equal under_no_cap, under_production_cap
    end
  end

  # --- Degrading rather than raising ----------------------------------------

  # The retry is only safe because scanning line by line finds exactly what
  # scanning the whole string finds — no pattern can match across a newline, and
  # every `preceded_by` name is `\z`-anchored, so nothing straddles a line
  # boundary. That is the property a future pattern could silently break, so it
  # is asserted against the real, undegraded output rather than spot-checked.
  test "a pattern pass that times out retries line by line and finds exactly what it would have found" do
    content = "sk-ant-oat01-#{'A1b2C3d4E5' * 4}\nUNSCANNABLE\n" + transcript_with_credentials(padding_bytes: 8 * 1024)
    # Times out on the whole transcript (it contains the poison line) but
    # succeeds on each line that does not.
    original = TranscriptRedactor.method(:apply_patterns)
    scanner = lambda do |text|
      raise Regexp::TimeoutError, "regexp match timeout" if text.include?("UNSCANNABLE") && text.lines.length > 1

      original.call(text)
    end

    TranscriptRedactor.stub(:known_secrets, []) do
      undegraded = TranscriptRedactor.redact(content)

      TranscriptRedactor.stub(:apply_patterns, scanner) do
        redacted = TranscriptRedactor.redact(content)

        assert_equal undegraded, redacted
        assert_includes redacted, "[REDACTED:MATCH:ANTHROPIC_OAUTH_TOKEN:"
        assert_includes redacted, "[REDACTED:MATCH:ENV_SECRET:"
        assert_includes redacted, "UNSCANNABLE"
        assert_equal content.lines.length, redacted.lines.length
      end
    end
  end

  test "a line no pattern pass can finish is replaced whole rather than emitted or dropped" do
    content = "ok before\nPOISON secret-looking-value\nok after\n"
    original = TranscriptRedactor.method(:apply_patterns)
    scanner = lambda do |text|
      raise Regexp::TimeoutError, "regexp match timeout" if text.include?("POISON")

      original.call(text)
    end

    TranscriptRedactor.stub(:known_secrets, []) do
      TranscriptRedactor.stub(:apply_patterns, scanner) do
        redacted = TranscriptRedactor.redact(content)

        refute_includes redacted, "POISON"
        assert_includes redacted, "[REDACTED:UNSCANNABLE_LINE:"
        assert_includes redacted, "ok before"
        assert_includes redacted, "ok after"
        assert_equal content.lines.length, redacted.lines.length
        assert redacted.end_with?("\n")
      end
    end
  end
end
