# frozen_string_literal: true

# PiTurnError — the error a Pi turn ended on, as Pi itself recorded it in the
# session JSONL, and which of Zimmer's recovery paths (if any) it belongs to.
#
# It is the Pi counterpart to CodexTurnError, read through the same
# RecordedTurnError seam, and it differs from it in one way that matters: for
# two of the failure classes Pi produces, the honest answer is "no recovery
# path owns this". Those get their own terminal kinds rather than being routed
# to a service that cannot act on them. See "What Pi does NOT recover from".
#
# == Where it comes from ==
#
# Pi records a failed model call as an assistant message with no content, a
# `stopReason` of "error", and the provider's own wording on `errorMessage`:
#
#   {"type":"message","id":"6d5e2e92","parentId":"52c2e1f2","timestamp":"…",
#    "message":{"role":"assistant","content":[],"api":"openai-completions",
#      "provider":"sim","model":"sim-model","usage":{…},"stopReason":"error",
#      "errorMessage":"401: {\"message\":\"Incorrect API key provided.\", …}"}}
#
# The process **exits 0** when that happens — Pi's exit code says whether `pi`
# itself ran, not whether the model answered — so this record is the only
# evidence the turn died. Nothing reaches stderr.
#
# == The evidence ==
#
# Every shape below was produced by the real `pi 0.84.4` binary (the version in
# the Zimmer base image) driven against a local OpenAI-completions stub
# returning each failure. Every one of them exited 0.
#
#   backend said                  Pi's errorMessage (abridged)                      kind
#   ---------------------------   -----------------------------------------------   ----------------------
#   500                           500: {"message":"The server had an error …"}      :retryable
#   502 (non-JSON body)           502 <html><body><h1>502 Bad Gateway</h1>…         :retryable
#   503 overloaded_error          503: {"message":"The engine is currently …"}      :retryable
#   429 rate_limit_exceeded       429: {"message":"Rate limit reached for …"}       :retryable
#   429 insufficient_quota        429: {"message":"You exceeded your current …"}    :retryable
#   408 timeout                   408: {"message":"Request timed out.", …}          :retryable
#   stream closed mid-response    terminated                                        :retryable
#   connection refused            Connection error.                                 :retryable
#   non-HTTP bytes, socket close  Connection error.                                 :retryable
#   401 invalid_api_key           401: {"message":"Incorrect API key provided…"}    :auth_terminal
#   403 permission_denied         403: {"message":"You are not allowed to …"}       :auth_terminal
#   402 insufficient credits      402: {"message":"Insufficient credits. …"}        :auth_terminal
#   400 context_length_exceeded   400: {"message":"This model's maximum context …"} :context_length_terminal
#   400 invalid_value             400: {"message":"Invalid value for 'temperature'…"} :request_rejected
#
# Two things about that table are Pi behaviours rather than provider ones. **Pi
# retries some of these itself** before it gives up: a 5xx, a rate-limit 429 and
# a transport failure each produced three or four consecutive error records in
# one run, so an error that reaches Zimmer has already failed repeatedly — which
# is why Zimmer's own backoff applies on top, exactly as it does for Codex. And
# **the status prefix is not always followed by a colon**: a JSON error body is
# recorded as `NNN: {…}` and a non-JSON one (the 502 above) as `NNN <body>`,
# which is why #http_status matches on the digits and the delimiter rather than
# on `"NNN: "`.
#
# == Why the status decides, and the body almost never does ==
#
# The stub above speaks OpenAI's error dialect. **Production Pi does not**: every
# model ModelCatalog offers Pi is an `openrouter/*` id, and OpenRouter words its
# bodies differently — its context-window refusal carries a numeric `"code":400`
# rather than `"code":"context_length_exceeded"`, and it uses 402 for an
# exhausted balance. A classifier keyed on one provider's body strings would
# therefore misroute the provider Zimmer actually ships, and — because
# PiRetryStrategy#classifies_exits? is true — would turn every unrecognized
# shape into a page rather than a quiet failure.
#
# So #kind is decided by the **HTTP status**, which is Pi's own framing and is
# provider-independent, and the body is consulted for exactly one refinement: it
# can name a 400 as a context-window refusal when it happens to say so. A 4xx
# Zimmer has no more specific name for is `:request_rejected` — *recognized*,
# terminal, and not news. That is the point of the split: Zimmer read a status,
# so it understands the shape well enough that failing on it is not an unknown
# failure mode, even when it cannot name the sub-reason. Only a message with no
# status Zimmer could read and no transport wording it knows is `:unclassified`,
# and that one pages.
#
# The two transport wordings are the one place a string still decides, and they
# were narrowed by driving the binary rather than guessed: a refused connection,
# a non-HTTP response and a socket destroyed before any reply all collapse to
# the same `Connection error.`, because the SDK normalizes them. A wording not
# in that list arrives with no status and pages — which is the alert doing its
# job, and the signal to add it here.
#
# == What Pi does NOT recover from ==
#
# **Context length.** Pi has no `/compact` command; it compacts on its own
# schedule, driven by its own token accounting. It also does not compact on a
# plain resume, which is what makes Codex's context-window recovery work
# (RuntimeCliAdapter::ClassMethods#compacts_on_resume?). Driven against the real
# binary: a turn that died on a 400 `context_length_exceeded`, resumed with the
# same `--session-id`, wrote no `{"type":"compaction"}` record and re-sent the
# same conversation with one more user message appended — failing identically.
# So there is no compaction recovery to route to, and routing there anyway would
# spend the retry budget making the conversation longer. `:context_length_terminal`
# says that: recognized, named, and terminal.
#
# **Auth, and the balance behind it.** PiAuthProvider pools no accounts by design
# — Pi resolves a provider API key from the session environment per request — so
# AuthRecoveryService has no credential to rewrite and no account to rotate to.
# A 401, a 403 or a 402 is a fact about the key the session was handed and the
# account paying for it, not a transient condition, so `:auth_terminal` fails the
# session naming the provider's own words instead of rotating into nothing.
#
# 402 sits with them rather than with the retryable statuses deliberately: an
# exhausted balance does not refill on a backoff, so six attempts would spend the
# budget to reach the same end more slowly. That is also the shape of the gap
# this leaves — a pooled runtime answers a quota wall by rotating or by parking
# until QuotaResetCheckerJob wakes it, and Pi has neither a pool to rotate
# through nor a snapshot to wake on, so it fails. The 429 `insufficient_quota`
# row is the same gap read from the other side: it IS retried, because 429 does
# clear on its own, but nothing paces it.
#
# All three terminal kinds are `recognized?`, which is what keeps them out of the
# unclassified-failure alert: they are known failures with a known and
# deliberate disposition, not unknown ones.
class PiTurnError
  # The `stopReason` Pi writes on an assistant message whose model call failed.
  ERROR_STOP_REASON = "error"

  # The leading HTTP status Pi prefixes a provider error with. A JSON body
  # follows a colon (`401: {…}`), a non-JSON body follows a bare space
  # (`502 <html>…`), and a transport failure has no status at all.
  HTTP_STATUS_PREFIX = /\A(\d{3})(?=[:\s]|\z)/

  # Statuses that are a transient failure worth another attempt, beside the
  # whole 5xx class: 429 (the provider is pacing us) and 408 (the request timed
  # out). Both are retryable by what the status itself means, in any dialect.
  RETRYABLE_STATUSES = [ 408, 429 ].freeze

  # Statuses that say the credential or the account behind it cannot serve this
  # request: unauthenticated, forbidden, and out of credit. Pi pools no accounts,
  # so none of the three has a recovery — see "What Pi does NOT recover from".
  AUTH_STATUSES = [ 401, 402, 403 ].freeze

  # Pi's whole-message wording for a request that never got a response.
  # `terminated` is the stream closing mid-response; `Connection error.` is every
  # connection-level failure, which the SDK normalizes to one string (a refused
  # connection, a non-HTTP reply and a socket destroyed before any response all
  # produced it against the real binary). Matched against the entire message so
  # a provider error that merely mentions one of these words cannot be mistaken
  # for one.
  TRANSPORT_FAILURE_MESSAGES = [
    /\Aterminated\z/i,
    /\AConnection error\.?\z/i
  ].freeze

  # The provider's own error code for a prompt that outgrew the model's context
  # window, as it appears in the JSON body Pi passes through verbatim. Read as a
  # `"code"` FIELD rather than as a substring: an unrelated failure whose prose
  # happens to name context_length_exceeded (an upstream router reporting on a
  # sibling request, say) must not be classified by it.
  #
  # This is a refinement, never the thing that decides retry-vs-terminal: a 400
  # is terminal either way (see #kind), and a provider that words it differently
  # — OpenRouter sends a numeric `"code":400` — lands in `:request_rejected`,
  # which fails identically and equally quietly. All this buys is the more
  # precise name in the logs and the docs.
  CONTEXT_LENGTH_BODY_CODE = /"code"\s*:\s*"context_length_exceeded"/

  attr_reader :message, :id, :line

  # The terminal turn error in a serialized Pi session JSONL, or nil when the
  # latest turn did not end on one.
  #
  # Walks backwards, because only the end of the file is in question and a long
  # session's transcript runs to tens of thousands of lines that every exit would
  # otherwise parse. The walk stops at the last `type: "message"` record — Pi's
  # `model_change` / `thinking_level_change` / `compaction` records are
  # bookkeeping appended around messages, and a trailing one of those must not
  # make a terminal error look non-terminal.
  #
  # An unparseable line is skipped rather than ending the walk: the final line of
  # a transcript a live `pi` is still writing is routinely half-flushed, and
  # treating that as "no error" would read a dead turn as a live one.
  #
  # @param serialized [String, nil] the session JSONL
  # @return [PiTurnError, nil]
  def self.terminal(serialized)
    return nil if serialized.blank?

    lines = serialized.lines
    (lines.length - 1).downto(0) do |index|
      record = parse_record(lines[index])
      next unless record && record["type"] == "message"

      message = record["message"]
      return nil unless message.is_a?(Hash)
      return nil unless message["stopReason"] == ERROR_STOP_REASON

      text = message["errorMessage"]
      return nil if text.blank?

      # Pi's per-record id is stable and unique, so it is the identity of the
      # failed turn. A record written without one falls back to its line number.
      return new(message: text.to_s, id: record["id"].presence || "line:#{index + 1}", line: index + 1)
    end

    nil
  end

  # One JSONL record, or nil for a blank or unparseable line.
  def self.parse_record(raw)
    stripped = raw.to_s.strip
    return nil if stripped.empty?

    record = JSON.parse(stripped)
    record.is_a?(Hash) ? record : nil
  rescue JSON::ParserError
    nil
  end
  private_class_method :parse_record

  def initialize(message:, id:, line:)
    @message = message
    @id = id
    @line = line
  end

  # Which recovery path owns this error, decided by the HTTP status Pi recorded.
  #
  # Only :retryable names a path that can act. The three terminal kinds are
  # deliberate dead ends — see "What Pi does NOT recover from" above — and naming
  # them distinctly rather than reusing :context_length / :auth is what makes the
  # seam fail safe: no service looks for these kinds, so a Pi 401 cannot reach
  # AuthRecoveryService (which has nothing to rewrite) and a Pi context-length
  # 400 cannot reach ContextLengthRetryService (which has no compaction to
  # trigger), however the ladder is rearranged later.
  #
  # @return [Symbol] :retryable, :auth_terminal, :context_length_terminal,
  #   :request_rejected, or :unclassified
  def kind
    status = http_status
    return transport_failure? ? :retryable : :unclassified if status.nil?

    return :retryable if RETRYABLE_STATUSES.include?(status) || status.between?(500, 599)
    return :auth_terminal if AUTH_STATUSES.include?(status)
    return :context_length_terminal if status == 400 && message.match?(CONTEXT_LENGTH_BODY_CODE)
    return :request_rejected if status.between?(400, 499)

    # A 1xx/2xx/3xx on a turn Pi called failed is a shape nothing here predicts.
    :unclassified
  end

  # Whether Zimmer understands this error well enough that failing on it is not
  # news. True for everything it could read a status from, and for the transport
  # wordings it knows — false only for :unclassified, which is the one worth an
  # alert. The terminal kinds are recognized: they end the session, but they are
  # not a mystery.
  def recognized?
    kind != :unclassified
  end

  # A 429 that outlasted Pi's own retries. Drives the retry service's log wording
  # only; Pi 429s never reach GlobalRateLimitTracker, which measures pressure on
  # the Anthropic API rather than on Pi's provider.
  def rate_limited?
    http_status == 429
  end

  # The HTTP status Pi prefixed the provider's error with, or nil for a transport
  # failure that never got a response.
  #
  # @return [Integer, nil]
  # Matched against the STRIPPED message: a leading newline would otherwise cost
  # the status, and a 500 that lost its status would be retried no longer.
  def http_status
    match = message.strip.match(HTTP_STATUS_PREFIX)
    match && match[1].to_i
  end

  private

  def transport_failure?
    stripped = message.strip
    TRANSPORT_FAILURE_MESSAGES.any? { |pattern| stripped.match?(pattern) }
  end
end
