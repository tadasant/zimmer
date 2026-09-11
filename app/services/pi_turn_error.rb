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
#   stream closed mid-response    terminated                                        :retryable
#   connection refused            Connection error.                                 :retryable
#   401 invalid_api_key           401: {"message":"Incorrect API key provided…"}    :auth_terminal
#   403 permission_denied         403: {"message":"You are not allowed to …"}       :auth_terminal
#   400 context_length_exceeded   400: {"message":"This model's maximum context …"} :context_length_terminal
#   400 invalid_value             400: {"message":"Invalid value for 'temperature'…"} :unclassified
#
# Two things about that table are worth stating, because they are Pi behaviours
# rather than provider ones. **Pi retries some of these itself** before it gives
# up: a 5xx, a rate-limit 429 and a transport failure each produced three or
# four consecutive error records in one run, so an error that reaches Zimmer has
# already failed repeatedly — which is why Zimmer's own backoff applies on top,
# exactly as it does for Codex. And **the status prefix is not always followed
# by a colon**: a JSON error body is recorded as `NNN: {…}` and a non-JSON one
# (the 502 above) as `NNN <body>`, which is why #http_status matches on the
# digits and the delimiter rather than on `"NNN: "`.
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
# **Auth.** PiAuthProvider pools no accounts by design — Pi resolves a provider
# API key from the session environment per request — so AuthRecoveryService has
# no credential to rewrite and no account to rotate to. A 401 or 403 is a
# configuration fact about the key the session was handed, not a transient
# condition, so `:auth_terminal` fails the session naming the provider's own
# words instead of rotating into nothing.
#
# Both kinds are `recognized?`, which is what keeps them out of the
# unclassified-failure alert: they are known failures with a known and
# deliberate disposition, not unknown ones.
class PiTurnError
  # The `stopReason` Pi writes on an assistant message whose model call failed.
  ERROR_STOP_REASON = "error"

  # The leading HTTP status Pi prefixes a provider error with. A JSON body
  # follows a colon (`401: {…}`), a non-JSON body follows a bare space
  # (`502 <html>…`), and a transport failure has no status at all.
  HTTP_STATUS_PREFIX = /\A(\d{3})(?=[:\s]|\z)/

  # Pi's whole-message wording for a request that never completed: `terminated`
  # is the stream closing mid-response, `Connection error.` is a connection that
  # was never established. Both were produced against the real binary, both are
  # the network rather than the request, and both are worth another attempt.
  # Matched against the entire message so a provider error that merely mentions
  # one of these words cannot be mistaken for one.
  TRANSPORT_FAILURE_MESSAGES = [
    /\Aterminated\z/i,
    /\AConnection error\.?\z/i
  ].freeze

  # The provider's own error code for a prompt that outgrew the model's context
  # window, as it appears in the JSON body Pi passes through verbatim. Read as a
  # `"code"` FIELD rather than as a substring: an unrelated failure whose prose
  # happens to name context_length_exceeded (an upstream router reporting on a
  # sibling request, say) must not be classified by it. Paired with a 400 status,
  # which is the only status the providers use for it.
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

  # Which recovery path owns this error.
  #
  # Only :retryable names a path that can actually act. The two `_terminal`
  # kinds are deliberate dead ends — see "What Pi does NOT recover from" above —
  # and naming them distinctly rather than reusing :context_length / :auth is
  # what makes the seam fail safe: no service looks for these kinds, so a Pi 401
  # cannot reach AuthRecoveryService (which has nothing to rewrite) and a Pi
  # context-length 400 cannot reach ContextLengthRetryService (which has no
  # compaction to trigger), however the ladder is rearranged later.
  #
  # @return [Symbol] :retryable, :auth_terminal, :context_length_terminal, or :unclassified
  def kind
    return :context_length_terminal if context_length_exceeded?
    return :auth_terminal if [ 401, 403 ].include?(http_status)
    return :retryable if http_status == 429 || http_status.to_i.between?(500, 599)
    return :retryable if transport_failure?

    :unclassified
  end

  # Whether this error is one Zimmer knows — false only for :unclassified, which
  # is the one worth an alert. The two terminal kinds are recognized: they end
  # the session, but they are not news.
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
  def http_status
    match = message.match(HTTP_STATUS_PREFIX)
    match && match[1].to_i
  end

  private

  def context_length_exceeded?
    http_status == 400 && message.match?(CONTEXT_LENGTH_BODY_CODE)
  end

  def transport_failure?
    stripped = message.strip
    TRANSPORT_FAILURE_MESSAGES.any? { |pattern| stripped.match?(pattern) }
  end
end
