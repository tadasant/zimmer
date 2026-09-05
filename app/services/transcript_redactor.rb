# frozen_string_literal: true

# Secret redaction for agent transcripts.
#
# ## Why this exists
#
# A transcript is a verbatim recording of everything an agent read, printed and
# was told. Zimmer hands its agents real credentials — MCP `${VAR}` values are
# interpolated into `.mcp.json` inside the clone, OAuth tokens are written to
# `~/.claude/.credentials.json`, `git` speaks to GitHub over an authenticated
# remote. An agent that `cat`s any of those files, echoes an environment
# variable, or pastes a `curl -H "Authorization: Bearer ..."` into its own
# reasoning puts that credential into the transcript, and the transcript is
# persisted (`sessions.transcript`, `subagent_transcripts.transcript`), served
# by the UI, and downloadable through the transcript-archive API.
#
# ## Defense in depth, not a guarantee
#
# This redactor lowers the blast radius of a transcript that escapes. It does
# NOT make transcripts safe to expose. It cannot recognize a credential with no
# recognizable shape that Zimmer never issued — a password an agent read out of
# a customer's config file, the body of an `op read` result, a session cookie
# from a browser automation run. Keep treating transcripts as secret material.
#
# ## Two tiers
#
#   1. **Known values.** Every `${VAR}` the AIR catalog's MCP servers reference,
#      resolved through the same `SecretProviders` chain that injects them into a
#      session, plus the OAuth tokens Zimmer stores in its own database. These
#      are exact string matches: no false positives, and they cover
#      Zimmer-specific credential formats that no regex could know about.
#   2. **Shapes.** High-confidence patterns for credentials with a recognizable
#      prefix or framing. Ported from the upstream OpenTranscripts reference
#      redactor (`vendor/open_transcripts/upstream/redaction.py`) and extended
#      with the shapes this system actually handles.
#
# ## Deliberately conservative
#
# Over-redaction destroys the debugging value that is the entire point of
# keeping transcripts, so there is no generic "high-entropy string" heuristic
# here. A pattern earns its place by having a literal anchor (`sk-ant-`,
# `-----BEGIN`, `Authorization: Bearer`) or by sitting immediately after a
# name that says the value is a credential.
#
# ## Newline-preserving, on purpose
#
# Redaction never adds or removes a line. The transcript pipeline compares line
# counts to tell a lost transcript from a rotated one
# (`Session#transcript_regression?`, `TranscriptPollerService#carryover_prefix`),
# so a redactor that collapsed a multi-line PEM block into one line would read as
# history loss. Every pattern here is therefore written so it CANNOT match across
# a newline — `[ \t]` rather than `\s`, negated classes rather than `[\s\S]` —
# and every replacement is newline-free. That also stops a `.+?` span from
# swallowing the unrelated events sitting between two markers.
#
# The one shape that genuinely spans lines, an armored PEM block, is found by a
# bounded line walk and replaced line for line.
#
# ## Off the global one-second regexp cap, on purpose
#
# `config.load_defaults 8.0` sets `Regexp.timeout = 1` process-wide. That cap is
# sized for request-scoped strings, and it applies to a *single* search — not to
# a `gsub` as a whole. A transcript is a multi-megabyte file, so two ordinary
# things reach it, both measured on a real 32 MB session transcript:
#
#   * A gap. A `gsub` is a sequence of searches, one per stretch between matches,
#     and DB_CONNECTION_STRING — a case-insensitive alternation with no literal
#     to seek — scans a whole transcript that holds no database URL as one
#     search. It raised at exactly 1.000 s.
#   * A match. One line carrying a 3.5 MB base64 tool result is a single
#     uninterrupted run of ENV_SECRET's value class, so that rule's greedy repeat
#     consumes the entire run in one match. It raised at 2.2 s.
#
# Neither is a bad transcript; both are what a big one looks like. The
# `Regexp::TimeoutError` propagated out of `TranscriptSource#read` into
# `TranscriptPollerService#poll_and_broadcast`, which logged
# `Error polling transcript for session N: regexp match timeout`, dropped the
# whole transcript update, and paged `#alerts` on the ERROR record — every poll,
# for as long as the session stayed alive (#472).
#
# The cap is not what keeps this scan honest, so every regexp that can be handed
# transcript-scale input carries its own SCAN_TIMEOUT instead, and the pattern
# pass degrades rather than raising. See SCAN_TIMEOUT and .scan_patterns.
module TranscriptRedactor
  # A credential value shorter than this is not distinguishable from ordinary
  # text, and redacting every occurrence of it would shred the transcript.
  MIN_KNOWN_SECRET_LENGTH = 12

  # How long a resolved known-secret set is reused before it is rebuilt. Short
  # enough that a rotated credential starts being redacted within a minute;
  # long enough that a poll every couple of seconds does not re-read the
  # Parameter Store and three tables each time.
  KNOWN_SECRETS_TTL = 60

  # jsonb keys whose string values are treated as credentials when scanning
  # ClaudeAccount#oauth_config, whose shape differs per runtime.
  SENSITIVE_KEY = /token|secret|key|password|credential/i

  # Depth cap for that scan. `oauth_config` is operator/CLI-supplied jsonb, and
  # SystemStackError is not a StandardError — an unguarded recursion would
  # escape the rescue around the build and take the poll down with it.
  MAX_JSON_DEPTH = 32

  # Guards the memoized known-credential set. A constant rather than `@mutex
  # ||= Mutex.new`, which can hand two racing threads two different mutexes.
  MUTEX = Mutex.new

  # `:whole` replaces the entire match. `:value` replaces only capture group 1,
  # leaving the surrounding framing (the variable name, the `Bearer` keyword,
  # the database host) readable.
  #
  # `preceded_by` is a performance seam, not a semantic one: a match only counts
  # when the text immediately before it also matches that regexp. It exists
  # because the generic ENV_SECRET rule is the difference between a redactor
  # that costs 25ms per megabyte and one that costs 200ms — see ENV_SECRET below.
  Pattern = Struct.new(:label, :regexp, :mode, :preceded_by)

  # The cap that replaces the global `Regexp.timeout` for every regexp here that
  # can be handed a whole transcript or a whole transcript line.
  #
  # It is a ReDoS backstop, not a latency budget, and — like the cap it replaces
  # — it bounds one search rather than a whole `gsub`. So the number to compare
  # it against is the slowest *single* search measured against production
  # transcripts, 2.2 s: ENV_SECRET over a 3.5 MB base64 run. Ten seconds leaves
  # that four times the room it needs while still killing a genuinely
  # exponential backtrack in bounded time. It says nothing about how long
  # .redact takes overall, which is a whole 32 MB transcript in ~7.6 s.
  #
  # The `preceded_by` regexps are deliberately left on the global cap: they only
  # ever run against a PRECEDING_WINDOW-byte slice.
  SCAN_TIMEOUT = 10.0

  # Recompile with SCAN_TIMEOUT. A regexp's own timeout takes precedence over
  # `Regexp.timeout`.
  #
  # `source` plus `options` is a faithful round-trip for an ASCII-only pattern
  # with no encoding flag, which every pattern in this file is. It is NOT
  # faithful in general: `options` does not carry the fixed-encoding bit, so a
  # `/u`, `/e` or `/s` pattern — or one with a non-ASCII literal in it — would
  # come back out encoding-agnostic. Patterns get added here routinely, so that
  # is a guard rather than a caveat in a comment.
  def self.bounded(regexp)
    if regexp.fixed_encoding? || !regexp.source.ascii_only?
      raise ArgumentError, "TranscriptRedactor.bounded cannot round-trip an encoding-bound pattern: #{regexp.inspect}"
    end

    Regexp.new(regexp.source, regexp.options, timeout: SCAN_TIMEOUT)
  end
  private_class_method :bounded

  def self.pattern(label, regexp, mode = :whole, preceded_by: nil)
    Pattern.new(label, bounded(regexp), mode, preceded_by).freeze
  end
  private_class_method :pattern

  # How far back the `preceded_by` check looks. Long enough for the longest
  # credential name plus quoting, short enough that the slice is free.
  PRECEDING_WINDOW = 32

  # Left boundary for a prefixed-token pattern: the prefix must begin a token,
  # not sit in the middle of one. Stricter than `\b`, which treats `-` as a
  # boundary and so would still match the `sk-` inside `task-sk-…`.
  TOKEN_START = /(?<![A-Za-z0-9_\-])/

  # Order matters: the first pattern to match a span wins, because its
  # replacement no longer looks like a credential to the patterns after it. The
  # specific labels come before the generic `ENV_SECRET` catch so a redaction is
  # labelled with what it actually was.
  PATTERNS = [
    # Anthropic OAuth access/refresh tokens. What ClaudeAccount#oauth_config and
    # ~/.claude/.credentials.json hold; an agent debugging its own auth prints
    # these. Listed before the generic Anthropic key so the label stays precise.
    pattern("ANTHROPIC_OAUTH_TOKEN", /#{TOKEN_START}sk-ant-(?:oat|ort)\d{2}-[A-Za-z0-9_\-]{16,}/o),
    pattern("ANTHROPIC_API_KEY", /#{TOKEN_START}sk-ant-[A-Za-z0-9_\-]{20,}/o),
    # OpenAI / Codex. Runs after the Anthropic patterns, which share the `sk-`
    # prefix and have already claimed their matches.
    #
    # TOKEN_START is load-bearing here, not decoration. `-` is in the value
    # class, so without a left boundary this matches inside ordinary hyphenated
    # prose: "ri|sk-assessment-frameworks" and "docs/ri|sk-mitigation-strategy"
    # both redact. `\b` alone is not enough either — it would still fire on
    # "task-sk-something-long-enough".
    pattern("OPENAI_API_KEY", /#{TOKEN_START}sk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_\-]{20,}/o),
    # GitHub. Every session pushes branches and drives `gh`.
    pattern("GITHUB_TOKEN", /#{TOKEN_START}gh[pousr]_[A-Za-z0-9]{36,}/o),
    pattern("GITHUB_TOKEN", /#{TOKEN_START}github_pat_[A-Za-z0-9_]{22,}/o),
    # Slack. `SLACK_BOT_TOKEN` is a catalog `${VAR}`, and the OAuth connector
    # mints user tokens of the same shape.
    pattern("SLACK_TOKEN", /#{TOKEN_START}xox[abprse]-[A-Za-z0-9\-]{10,}/o),
    pattern("SLACK_APP_TOKEN", /#{TOKEN_START}xapp-\d-[A-Za-z0-9\-]{10,}/o),
    # Google. The Parameter Store resolver authenticates with a service account.
    pattern("GOOGLE_API_KEY", /\bAIza[0-9A-Za-z_\-]{35}\b/),
    pattern("GOOGLE_OAUTH_CLIENT_SECRET", /\bGOCSPX-[A-Za-z0-9_\-]{20,}/),
    pattern("AWS_ACCESS_KEY_ID", /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/),
    pattern("AWS_SECRET_ACCESS_KEY", /aws_secret_access_key["']?[ \t]*[:=][ \t]*["']?([A-Za-z0-9\/+=]{40})/i, :value),
    # Stripe. Not a credential Zimmer itself issues — carried over from the
    # upstream reference redactor, which Zimmer's pattern set is a superset of
    # (asserted by test/services/open_transcript_drift_test.rb). The `sk_live_`
    # form is underscore-separated and so is missed by the `sk-` patterns above.
    pattern("STRIPE_KEY", /\b(?:sk|rk|pk)_(?:live|test)_[0-9a-zA-Z]{16,}/),
    pattern("NPM_TOKEN", /\bnpm_[A-Za-z0-9]{30,}/),
    # 1Password service-account token — the credential the `1password-provisioning`
    # MCP server runs on. The `op://` references it consumes are not secret; its
    # token is, and so is anything `op read` prints (which has no shape and is
    # therefore NOT covered here).
    pattern("OP_SERVICE_ACCOUNT_TOKEN", /\bops_[A-Za-z0-9+\/=_\-]{40,}/),
    # JWTs: OAuth id tokens, Google access tokens, MCP bearer credentials.
    pattern("JWT", /\bey[A-Za-z0-9_\-]{10,}\.ey[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}/),
    # PEM blocks that arrive escaped inside a JSON string (a service account's
    # `private_key`, an SSH key `cat`ed into a tool result). Real multi-line PEM
    # blocks are handled by the block tracker in .redact.
    pattern(
      "PRIVATE_KEY",
      /-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----(?:(?!-----END)[^\n])*-----END (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----/
    ),
    # `Authorization: Bearer …` / `Authorization: Basic …`. Zimmer's own catalog
    # ships `"Authorization": "Bearer ${STRAD_API_KEY}"`, and OTEL export uses a
    # bearer token.
    pattern("BEARER_TOKEN", /bearer[ \t]+([A-Za-z0-9_\-.=]{20,})/i, :value),
    # `Basic` needs the `Authorization` in front of it, unlike `Bearer`. Its
    # value class has to include `/` and `+` to cover base64, and "basic" is an
    # ordinary English word, so unanchored it eats a path or a slashed phrase:
    # "basic app/models/session works" and "the basic authentication/authorization
    # flow" both redacted before this anchor existed.
    pattern(
      "BASIC_AUTH",
      /basic[ \t]+([A-Za-z0-9+\/=]{16,})/i,
      :value,
      preceded_by: /authorization["']?[ \t]*[:=][ \t]*["']?\z/i
    ),
    # `X-API-Key: …` headers — how the catalog passes `${ZIMMER_PROD_API_KEY}`
    # and how Zimmer's own REST API is authenticated.
    pattern("API_KEY_HEADER", /\b(?:x-api-key|api-key|x-auth-token)["']?[ \t]*[:=][ \t]*["']?([A-Za-z0-9+\/=_\-]{16,})/i, :value),
    # Credentials embedded in a URL: an authenticated git remote
    # (https://x-access-token:…@github.com) or a database URL.
    pattern("URL_CREDENTIALS", /\bhttps?:\/\/[^:\/\s@"']+:([^@\s\/"']{8,})@/, :value),
    # The userinfo-only form, `https://<token>@github.com/…`, which `gh` and a
    # token-authenticated `git remote` both produce. No colon, so the rule above
    # does not see it. The 20-character floor is what keeps an ordinary
    # `https://user@host` URL out of it.
    pattern("URL_CREDENTIALS", /\bhttps?:\/\/([A-Za-z0-9_\-.~+\/=]{20,})@/, :value),
    pattern(
      "DB_CONNECTION_STRING",
      /\b(?:postgres|postgresql|mysql|mongodb(?:\+srv)?|redis|rediss|amqp|amqps):\/\/[^:\s\/@"']+:([^@\s"']+)@/i,
      :value
    ),
    # The generic catch, last: a name that says "credential" followed
    # immediately by a value that looks like one.
    #
    # Three deliberate choices. The value character class excludes `.`, which is
    # what leaves `apiKey: process.env.FOO` (source code an agent is editing)
    # alone; JWTs have their own pattern above. The name is NOT `\b`-anchored,
    # because the shape that actually shows up is `RAILS_MASTER_KEY=…` and `_`
    # is a word character, so a leading `\b` would miss every
    # SCREAMING_SNAKE_CASE variable there is.
    #
    # And the name is checked *after* the match, not inside it. Leading with an
    # eighteen-way case-insensitive alternation gives the regex engine no literal
    # to seek, so it retries all eighteen at every offset in a multi-megabyte
    # transcript — measured at ~200ms/MB on every poll. Anchoring on `[:=]`
    # followed by a long value narrows a megabyte to a few thousand candidates
    # in ~25ms, and each candidate's name is then confirmed exactly against a
    # 32-character window. Same matches, an order of magnitude cheaper.
    pattern(
      "ENV_SECRET",
      /[:=][ \t]*["']?([A-Za-z0-9+\/=_\-]{16,})/,
      :value,
      preceded_by: /(?:api[_-]?key|apikey|secret[_-]?key|secret|password|passwd|passphrase|access[_-]?token|refresh[_-]?token|id[_-]?token|auth[_-]?token|session[_-]?token|bot[_-]?token|access[_-]?key|private[_-]?key|client[_-]?secret|master[_-]?key|token)["']?\z/i
    )
  ].freeze

  # Bounded like the rules above: the BEGIN guard is matched against the whole
  # transcript, and the other two against a whole line.
  PRIVATE_KEY_BEGIN = bounded(/-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----/)
  PRIVATE_KEY_END = bounded(/-----END (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----/)
  # A 4096-bit RSA key armors to ~51 body lines; nothing legitimate is longer
  # than this. The cap is what stops a stray `-----BEGIN PRIVATE KEY-----` in
  # prose from opening a block that eats the rest of the transcript.
  MAX_PRIVATE_KEY_BLOCK_LINES = 200
  # Base64 armor, or one of the two RFC 1421 header lines an encrypted PEM
  # carries. Only those two names, not any `Word: value` line — a general header
  # rule would let ordinary prose bridge a BEGIN and an END that both appear in
  # running text, which is the exact over-redaction the block walk exists to
  # avoid.
  PRIVATE_KEY_BODY_LINE = bounded(/\A(?:[A-Za-z0-9+\/=]*|(?:Proc-Type|DEK-Info):[ \t]?\S.*)\z/)

  class << self
    # Redact a whole transcript (or any transcript-shaped blob).
    #
    # Line count is preserved exactly, including whether the final line carries
    # a terminator, so the poller's regression/rotation arithmetic is unchanged.
    #
    # @param content [String, nil]
    # @return [String, nil] the redacted content; nil/empty input is returned as-is
    def redact(content)
      return content unless content.is_a?(String)
      return content if content.empty?

      out = content
      out = out.scrub("") unless out.valid_encoding?
      # Multi-line PEM armor is the one shape that has to be found by walking
      # lines. Everything after it scans the whole string once per pattern: a
      # transcript is megabytes and is re-read on every poll, so paying per-line
      # call overhead once per pattern per line is not affordable. How
      # unaffordable depends on how long the lines are — measured over 4 MB, 3.1x
      # the whole-string cost at 80 bytes a line, 2.2x at 400, 1.3x at 4 KB, and
      # 1.1x on a real 15.5 MB transcript, whose lines average 3 KB. It is also
      # what .scan_patterns falls back to, where paying it once beats dropping
      # the update.
      out = redact_armored_private_keys(out)

      # Exact string search, not a regexp, so no timeout applies here at all.
      known_secrets.each do |value, label|
        next unless out.include?(value)

        out = out.gsub(value, marker(label))
      end
      scan_patterns(out)
    end

    # The known-credential set, as [value, label] pairs ordered longest-first so
    # a credential that contains another credential as a substring is replaced
    # whole rather than shredded from the inside out.
    #
    # Never memoized into Rails.cache: that store can be Redis, and writing the
    # deployment's credentials into it to make redaction faster would be a
    # strictly worse trade than the one this class exists to make.
    #
    # @return [Array<Array(String, String)>]
    def known_secrets
      cached = cached_known_secrets
      return cached if cached

      # Built OUTSIDE the lock on purpose. The build shells out to the AIR
      # catalog, may make Parameter Store round-trips, and reads three tables;
      # holding the lock across it would park every poller thread calling #read
      # behind one slow secret store. Two threads racing past an expiry both
      # build the same set from the same sources, so the duplicated work is
      # bounded and the result is identical either way — a far better trade than
      # head-of-line blocking the transcript pipeline.
      built = build_known_secrets

      MUTEX.synchronize do
        @known_secrets = built
        @known_secrets_loaded_at = monotonic_now
      end

      built
    end

    # Where the first line that could OPEN a multi-line PEM block starts.
    #
    # Everything else in .redact is line-decomposable — no pattern can match
    # across a newline — so the multi-line armor walk is the ONLY reason a
    # transcript cannot be redacted a piece at a time. Anything that wants to
    # split the text (TranscriptRedactionCache, which reuses an already-redacted
    # prefix rather than re-scanning it every poll) has to know where that walk
    # could reach across a cut, and the answer lives here rather than in the
    # caller so it stays in step with .redact_armored_private_keys' own rule for
    # what opens a block.
    #
    # The escaped-in-JSON form, which carries BEGIN and END on one line, is a
    # PATTERNS entry rather than a block and so does not count as an opener.
    #
    # @param text [String] valid-encoding text; .redact scrubs before the walk
    #   sees anything, and TranscriptRedactionCache scrubs before it asks
    # @return [Integer, nil] byte offset of the opening line, or nil when the
    #   text holds no line that could open a block
    def private_key_block_start(text)
      return nil unless text.is_a?(String)
      # `String#match?` raises ArgumentError on a broken byte sequence. The
      # conservative answer is "an opener at byte 0", which tells a caller that
      # nothing may be split off — never "no opener", which would let one commit
      # past armor it could not see.
      return 0 unless text.valid_encoding?
      # One literal-prefixed scan (13 ms over 32 MB) skips the walk entirely on
      # the overwhelmingly common transcript that mentions no PEM at all.
      return nil unless holds_private_key_marker?(text)

      offset = 0
      text.each_line do |line|
        return offset if line.match?(PRIVATE_KEY_BEGIN) && !line.match?(PRIVATE_KEY_END)

        offset += line.bytesize
      end
      nil
    end

    # Drop the cached known-credential set. Used by tests and after a rotation.
    def reset_known_secrets!
      MUTEX.synchronize do
        @known_secrets = nil
        @known_secrets_loaded_at = nil
      end
    end

    private

    def cached_known_secrets
      MUTEX.synchronize do
        return nil if @known_secrets.nil? || @known_secrets_loaded_at.nil?
        return nil if (monotonic_now - @known_secrets_loaded_at) > KNOWN_SECRETS_TTL

        @known_secrets
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Run every pattern over the text, and never raise while doing it.
    #
    # SCAN_TIMEOUT is sized so that this path does not fire on any transcript
    # this system has produced. It exists because the alternative — letting
    # `Regexp::TimeoutError` escape — is what #472 was: the poller rescues it,
    # logs an ERROR, and drops the transcript update entirely, so one unscannable
    # line costs the session every message that arrived with it.
    #
    # Two tiers, because the cost is almost never spread evenly. A timeout means
    # one region of the text is pathological, so the first retry re-runs the
    # patterns line by line: every other line is scanned normally and only the
    # offending one is left. That line is then replaced whole. Destroying one
    # line of a transcript is worse than redacting it precisely and better than
    # both of the alternatives, which are dropping the update and emitting a line
    # no pattern was able to finish looking at.
    #
    # Both warnings below repeat on every poll for as long as the transcript
    # holds the line, because the poller re-reads and re-redacts the whole file
    # each time (#477). That is deliberate: a transcript this redactor cannot
    # read is worth saying every time, and WARN is a severity below the one the
    # alert rule watches.
    def scan_patterns(text)
      apply_patterns(text)
    rescue Regexp::TimeoutError => e
      Rails.logger.warn(
        "[TranscriptRedactor] pattern scan exceeded #{SCAN_TIMEOUT}s over #{text.bytesize} bytes " \
        "(#{e.class}); retrying line by line"
      )
      text.lines.map { |line| scan_line(line) }.join
    end

    def apply_patterns(text)
      PATTERNS.reduce(text) { |carry, pattern| apply(pattern, carry) }
    end

    # The terminator is preserved, so the line count survives a line this
    # redactor could not scan exactly as it survives one it could.
    def scan_line(line)
      apply_patterns(line)
    rescue Regexp::TimeoutError
      Rails.logger.warn(
        "[TranscriptRedactor] redacting a #{line.bytesize}-byte line whole: no pattern pass finished within #{SCAN_TIMEOUT}s"
      )
      redacted_line("UNSCANNABLE_LINE", line)
    end

    # Replace the lines of every well-formed multi-line PEM block, one marker
    # per line so the line count is untouched.
    #
    # A block counts only when a BEGIN marker is followed, within
    # MAX_PRIVATE_KEY_BLOCK_LINES, by a matching END marker with nothing but
    # base64 armor in between. Both bounds exist to keep prose that merely
    # *mentions* `-----BEGIN PRIVATE KEY-----` from redacting everything after
    # it — an over-redaction that would be far worse than the leak it prevents.
    #
    # The escaped-in-JSON form of a PEM (one JSONL record carrying `\n`
    # separators) opens and closes on the same line and is handled by the
    # single-line PRIVATE_KEY entry in PATTERNS instead.
    #
    # The BEGIN marker is a rare literal, so the whole walk is skipped with one
    # scan on the overwhelmingly common transcript that has no PEM in it.
    def redact_armored_private_keys(content)
      return content unless holds_private_key_marker?(content)

      lines = content.lines
      armored = Set.new
      index = 0

      while index < lines.length
        line = lines[index]
        unless line.match?(PRIVATE_KEY_BEGIN) && !line.match?(PRIVATE_KEY_END)
          index += 1
          next
        end

        closing = find_private_key_end(lines, index)
        if closing
          armored.merge(index..closing)
          index = closing + 1
        else
          index += 1
        end
      end

      return content if armored.empty?

      lines.each_with_index.map do |source, position|
        armored.include?(position) ? redacted_line("PRIVATE_KEY", source) : source
      end.join
    end

    # The only other search handed the whole transcript. PRIVATE_KEY_BEGIN is a
    # literal-prefixed alternation, so the engine seeks `-----BEGIN` rather than
    # trying every offset — 13 ms over 32 MB — and reaching SCAN_TIMEOUT here is
    # not a thing that can happen. It is rescued anyway because the answer on
    # timeout is "walk", not "skip": skipping is the optimization, and skipping
    # when a key IS there would be a leak.
    #
    # The walk's own per-line matches (this constant again, PRIVATE_KEY_END,
    # PRIVATE_KEY_BODY_LINE) are not rescued. They are the same shape — literal
    # prefix, or `\A`-anchored so a non-armor line fails at the first character
    # — and they carry SCAN_TIMEOUT like everything else, so the cap #472 was
    # about cannot reach them. What they do not have is a conservative answer
    # that is the same at all four call sites: "assume a timeout means key
    # material" closes a block at one and opens one at another. Rescuing them
    # would mean four different fallbacks for a case none of them can hit, so
    # the contract stops here — .scan_patterns is what cannot raise.
    def holds_private_key_marker?(content)
      content.match?(PRIVATE_KEY_BEGIN)
    rescue Regexp::TimeoutError
      true
    end

    def find_private_key_end(lines, begin_index)
      last = [ begin_index + MAX_PRIVATE_KEY_BLOCK_LINES, lines.length - 1 ].min

      ((begin_index + 1)..last).each do |index|
        body = lines[index].chomp
        return index if body.match?(PRIVATE_KEY_END)
        return nil unless body.match?(PRIVATE_KEY_BODY_LINE)
      end

      nil
    end

    def marker(label)
      "[REDACTED:#{label}]"
    end

    # Replace the whole line's content while keeping its terminator, so the
    # line count and the "does the last line end in a newline" property survive.
    def redacted_line(label, line)
      terminator = line.end_with?("\r\n") ? "\r\n" : (line.end_with?("\n") ? "\n" : "")
      marker(label) + terminator
    end

    # No `match?` guard before the `gsub`: a failed `match?` is a full scan of
    # its own, and on a transcript-sized string it measures *slower* than the
    # `gsub` it was meant to avoid.
    def apply(pattern, text)
      text.gsub(pattern.regexp) do |match|
        found = Regexp.last_match

        if pattern.preceded_by && !preceded_by?(text, found, pattern.preceded_by)
          next match
        end

        if pattern.mode == :value
          replace_capture(found, match, marker(pattern.label))
        else
          marker(pattern.label)
        end
      end
    end

    # Does the text immediately before this match end with `regexp`?
    #
    # Byte offsets and #byteslice, not MatchData#pre_match and not `text[a...b]`.
    # `pre_match` copies everything before the match — megabytes, once per
    # candidate. A character range is O(1) only in principle: measured over a
    # megabyte of transcript it costs ~5x what the equivalent byteslice does.
    # The window is forced to binary because a byte window can land mid-codepoint;
    # the name patterns are pure ASCII, so matching against binary is exact.
    def preceded_by?(text, found, regexp)
      start = found.byteoffset(0).first
      window = text.byteslice([ start - PRECEDING_WINDOW, 0 ].max, [ start, PRECEDING_WINDOW ].min)
      return false if window.nil? || window.empty?

      window.force_encoding(Encoding::BINARY).match?(regexp)
    end

    # Swap capture group 1 out of `match` by offset rather than by
    # `String#sub`, which would replace the wrong span when the captured value
    # also appears earlier inside the match.
    def replace_capture(match_data, match, replacement)
      start = match_data.begin(1) - match_data.begin(0)
      finish = match_data.end(1) - match_data.begin(0)
      match[0...start] + replacement + match[finish..]
    end

    def build_known_secrets
      values = {}
      collect_catalog_variables(values)
      collect_stored_oauth_tokens(values)
      values.sort_by { |value, _label| -value.length }
    end

    # Every `${VAR}` the catalog's MCP servers reference, resolved through the
    # same chain that materializes them into a session's `.mcp.json` /
    # `config.toml`. This is the tier that covers Zimmer-specific credentials
    # (ZIMMER_PROD_API_KEY, STRAD_API_KEY, a 1Password service-account token)
    # whose formats no regex knows.
    def collect_catalog_variables(values)
      names = ServersConfig.all.flat_map { |server| server.required_variables + server.optional_variables }.uniq
      names.each do |name|
        value = resolve_variable(name)
        next unless redactable?(value)

        values[value] ||= "ENV:#{name}"
      end
    rescue StandardError => e
      warn_degraded("catalog variables", e)
    end

    # Deliberately goes to SecretProviders rather than SecretsInterpolator: the
    # interpolator consults XOauthTokenVendor first, which MINTS a fresh access
    # token as a side effect. Building a redaction table must never spend a
    # credential. X tokens are picked up from the database below instead.
    def resolve_variable(name)
      SecretProviders.chain.get(name)
    rescue StandardError
      # A single unreachable provider must not cost us the rest of the table.
      nil
    end

    # OAuth material Zimmer holds itself. Covers refresh tokens and any
    # provider-specific access token shape the PATTERNS above would miss.
    def collect_stored_oauth_tokens(values)
      each_stored_token do |token|
        next unless redactable?(token)

        values[token] ||= "OAUTH_TOKEN"
      end
    rescue StandardError => e
      warn_degraded("stored OAuth tokens", e)
    end

    def each_stored_token(&block)
      McpOauthCredential.pluck(:access_token, :refresh_token).flatten.each(&block)
      XOauthCredential.pluck(:access_token, :refresh_token).flatten.each(&block)
      ClaudeAccount.pluck(:oauth_config).each do |config|
        deep_sensitive_strings(config).each(&block)
      end
    end

    # ClaudeAccount#oauth_config is a per-runtime jsonb blob (`credentials_json`
    # for Claude Code, `tokens`/`api_key` for Codex), so it is walked by key name
    # rather than by a fixed path that a runtime change would silently outdate.
    def deep_sensitive_strings(node, found = [], depth = 0)
      return found if depth > MAX_JSON_DEPTH

      case node
      when Hash
        node.each do |key, value|
          if value.is_a?(String) && key.to_s.match?(SENSITIVE_KEY)
            found << value
          else
            deep_sensitive_strings(value, found, depth + 1)
          end
        end
      when Array
        node.each { |value| deep_sensitive_strings(value, found, depth + 1) }
      end
      found
    end

    # A known value only earns exact-match redaction if redacting every
    # occurrence of it cannot plausibly destroy ordinary transcript text.
    def redactable?(value)
      value.is_a?(String) &&
        value.length >= MIN_KNOWN_SECRET_LENGTH &&
        value.match?(/\A\S+\z/) &&
        !value.match?(/\A(?:true|false|null|none|\d+)\z/i)
    end

    def warn_degraded(source, error)
      Rails.logger.warn(
        "[TranscriptRedactor] could not load #{source} (#{error.class}: #{error.message}); " \
        "redaction falls back to shape patterns for this window"
      )
    end
  end
end
