# frozen_string_literal: true

# CodexTurnError — the error a Codex turn ended on, as Codex itself recorded it
# in the rollout, and which of Zimmer's recovery paths it belongs to.
#
# == Where it comes from ==
#
# Every turn Codex runs ends with an `event_msg` whose payload `type` is
# `task_complete`. A turn that failed carries the reason on that record, with a
# machine-readable code beside the prose:
#
#   {"type":"event_msg","payload":{"type":"task_complete","turn_id":"01a0…",
#     "last_agent_message":null,
#     "error":{"message":"Codex ran out of room in the model's context window. …",
#              "codex_error_info":"context_window_exceeded"}}}
#
# The rollout is the right place to read it rather than the `--json` event
# stream (CodexEventStream): the stream's `turn.failed` carries the message
# alone, and it is also where Codex writes the NON-terminal
# `{"type":"error","message":"Reconnecting... 2/5 (…)"}` lines it emits while it
# retries on its own. Only the `task_complete` record says how the turn ended.
#
# == The evidence ==
#
# Every shape below was produced by the real codex-cli 0.146.0 binary (the
# version in the Zimmer base image) driven against a local fake of the ChatGPT
# backend returning each failure, over ChatGPT-OAuth auth. Every failure exits 1.
#
#   backend said                         codex_error_info                         message (abridged)
#   ----------------------------------   --------------------------------------   ------------------------------------------------
#   500                                  internal_server_error                    We're currently experiencing high demand, …
#   503                                  other                                    unexpected status 503 Service Unavailable: …
#   429 (rate limit, or HTTP quota)      {response_too_many_failed_attempts:      exceeded retry limit, last status: 429 Too Many Requests
#                                          {http_status_code: 429}}
#   stream server_is_overloaded          server_overloaded                        Selected model is at capacity. …
#   429 usage_limit_reached              usage_limit_exceeded                     You've hit your usage limit. … try again at 2:23 PM.
#   429 usage_not_included               usage_limit_exceeded                     To use Codex with your ChatGPT plan, upgrade to Plus: …
#   stream insufficient_quota            usage_limit_exceeded                     Quota exceeded. Check your plan and billing details.
#   stream context_length_exceeded       context_window_exceeded                  Codex ran out of room in the model's context window. …
#   400 context_length_exceeded          other                                    {"error": {… "code": "context_length_exceeded"}}
#   refresh token expired/revoked/used   unauthorized                             Your access token could not be refreshed because …
#   401 after a successful refresh       other                                    unexpected status 401 Unauthorized: …
#   400 invalid_value                    other                                    {"error": {… "code": "invalid_value"}}
#   stream closed before completing      other                                    stream disconnected before completion: stream closed …
#   connection refused                   other                                    stream disconnected before completion: error sending …
#
# Codex retries 5xx and 429 itself (five attempts) before it records the error,
# so by the time one reaches Zimmer the request has already failed repeatedly —
# which is why Zimmer's own backoff (ApiErrorRetryService) still applies on top.
#
# == Rate-limit windows ==
#
# Codex also records the account's rate-limit windows, parsed from the
# backend's `x-codex-{primary,secondary}-{used-percent,window-minutes,reset-at}`
# response headers, on `token_count` records — including the one it writes
# immediately before a usage-limit `task_complete`:
#
#   "rate_limits":{"primary":{"used_percent":100.0,"window_minutes":300,"resets_at":1789136947},
#                  "secondary":{"used_percent":42.5,"window_minutes":10080,"resets_at":1789533347}}
#
# That is when a quota-exceeded Codex account can serve again, and #quota_reading
# carries it to QuotaSnapshotService so QuotaResetCheckerJob can restore the
# account once it passes. A refusal without those headers gets a `token_count`
# whose windows are null, and that is recorded too — as a refusal with no known
# reset, so nothing restores the account on a guess.
class CodexTurnError
  # The rollout records that say a turn started or stopped. The LAST of them
  # decides whether there is a terminal error at all: a `task_started` after the
  # last `task_complete` is a turn that has not ended (or died without Codex
  # writing how), and it is not the earlier turn's error that it died on.
  TURN_LIFECYCLE_EVENTS = %w[task_started task_complete turn_aborted].freeze

  # Codex codes that are a transient upstream failure — the same class as a
  # Claude 5xx / overloaded error. The first two were produced by the fake
  # backend; the three transport codes are Codex's own names for a connection or
  # stream that failed, from the same `codex_error_info` enum in the 0.146.0
  # binary, and are retryable by what they name.
  RETRYABLE_CODES = %w[
    internal_server_error server_overloaded
    http_connection_failed response_stream_connection_failed response_stream_disconnected
  ].freeze

  # How Codex words a request that never got a response — a stream that closed
  # early, a connection refused — when it files it under `other` with no status.
  # Both were produced against the real binary; both are the network, not the
  # request, so both are worth another attempt.
  TRANSPORT_FAILURE_MESSAGE = /\Astream disconnected before completion:/

  # `unexpected status 503 …` / `exceeded retry limit, last status: 429 …` — the
  # two forms Codex puts an HTTP status into prose with, used when the code is
  # the catch-all `other`.
  HTTP_STATUS_IN_MESSAGE = /\b(?:unexpected status|last status:)\s+(\d{3})\b/

  # The API's own error code, passed through verbatim when Codex surfaces a raw
  # 400 body under `other`.
  CONTEXT_LENGTH_BODY_CODE = /"code"\s*:\s*"context_length_exceeded"/

  # The `anthropic-ratelimit-unified-*-status` value ClaudeAccountQuotaSnapshot
  # reads as "this window is refusing". A Codex refusal writes it on the windows
  # it was refused on, so the snapshot keeps refusing until their reset passes —
  # or, with no reset known, until a human re-activates the account.
  REFUSED_STATUS = "rejected"

  # The quota reading a refusal leaves behind, in the shape
  # QuotaSnapshotService.save_snapshot takes (QuotaCheckService::Result's
  # fields). Codex's primary window lands in the columns Claude's five-hour
  # window uses and its secondary window in the weekly ones;
  # ClaudeAccountQuotaSnapshot#windows_clear? — what the restore decides on —
  # asks about reset times, statuses and counters, not window lengths.
  QuotaReading = Data.define(:utilization_5h, :reset_5h, :status_5h, :utilization_7d, :reset_7d, :status_7d) do
    def subscription_type = nil
    def rate_limit_tier = nil
    def overage_status = nil
    def overage_disabled_reason = nil

    # When the account can serve again: the latest reset among the refused
    # windows, which is when ClaudeAccountQuotaSnapshot#windows_clear? turns true.
    # nil when a refused window has no reset time — then nothing restores it.
    #
    # @return [Time, nil]
    def restores_at
      resets = [ [ status_5h, reset_5h ], [ status_7d, reset_7d ] ]
        .select { |status, _reset| status == REFUSED_STATUS }
        .map(&:last)
      resets.all? ? resets.max : nil
    end
  end

  attr_reader :message, :info, :turn_id, :line, :rate_limits

  # The terminal turn error in a serialized rollout, or nil when the latest turn
  # did not end on one.
  #
  # Walks backwards, because only the end of the rollout is in question and a
  # long session's rollout runs to tens of thousands of lines that every exit
  # would otherwise parse. The walk stops at the last turn-lifecycle record, and,
  # when that is a failed `task_complete`, carries on to the turn's own
  # `task_started` collecting the turn's latest rate-limit reading — never an
  # earlier turn's, which may describe a different account.
  #
  # @param serialized [String, nil] the rollout's JSONL
  # @return [CodexTurnError, nil]
  def self.terminal(serialized)
    return nil if serialized.blank?

    lines = serialized.lines
    terminal = nil
    rate_limits = nil

    (lines.length - 1).downto(0) do |index|
      raw = lines[index]
      next unless raw.include?("event_msg")

      payload = event_payload(raw)
      next unless payload

      type = payload["type"]
      if terminal.nil?
        next unless TURN_LIFECYCLE_EVENTS.include?(type)
        return nil unless type == "task_complete" && payload["error"].is_a?(Hash)

        terminal = [ payload, index + 1 ]
      elsif type == "token_count" && rate_limits.nil? && payload["rate_limits"].is_a?(Hash)
        rate_limits = payload["rate_limits"]
      elsif type == "task_started"
        break
      end
    end

    return nil unless terminal

    payload, line_number = terminal
    error = payload["error"]
    new(
      message: error["message"].to_s,
      info: error["codex_error_info"],
      turn_id: payload["turn_id"].presence,
      line: line_number,
      rate_limits: rate_limits
    )
  end

  # The payload of an `event_msg` rollout line, or nil for anything else —
  # including a half-flushed final line, which is the normal state of a rollout
  # still being written.
  def self.event_payload(raw)
    record = JSON.parse(raw)
    return nil unless record.is_a?(Hash) && record["type"] == "event_msg"

    payload = record["payload"]
    payload.is_a?(Hash) ? payload : nil
  rescue JSON::ParserError
    nil
  end
  private_class_method :event_payload

  def initialize(message:, info:, turn_id:, line:, rate_limits: nil)
    @message = message
    @info = info
    @turn_id = turn_id
    @line = line
    @rate_limits = rate_limits
  end

  # Stable identity of the failed turn: what a recovery path records once it has
  # acted on it (RecordedTurnError), so the same dead turn is not acted on twice.
  # Codex mints a unique id per turn; the line number is the fallback for a
  # record written without one.
  #
  # @return [String]
  def id
    turn_id || "line:#{line}"
  end

  # Which recovery path owns this error.
  #
  # @return [Symbol] :context_length, :quota, :auth, :retryable, or :unclassified
  def kind
    return :context_length if context_window_exceeded?
    return :quota if code == "usage_limit_exceeded"
    return :auth if code == "unauthorized" || http_status == 401
    return :retryable if RETRYABLE_CODES.include?(code)
    return :retryable if http_status == 429 || http_status.to_i.between?(500, 599)
    return :retryable if code == "other" && message.match?(TRANSPORT_FAILURE_MESSAGE)

    :unclassified
  end

  # Whether some recovery path owns this error — false only for :unclassified,
  # which is the one worth an alert.
  def recognized?
    kind != :unclassified
  end

  # A 429 that outlasted Codex's own retries.
  def rate_limited?
    http_status == 429
  end

  # The `codex_error_info` code. A plain string for most errors; the single key
  # of an object for the ones that carry detail
  # (`{"response_too_many_failed_attempts":{"http_status_code":429}}`).
  #
  # @return [String, nil]
  def code
    case info
    when String then info
    when Hash then info.keys.first.to_s
    end
  end

  # The HTTP status behind the error, from the structured detail when Codex gave
  # one and from its prose otherwise.
  #
  # @return [Integer, nil]
  def http_status
    if info.is_a?(Hash)
      detail = info.values.first
      status = detail["http_status_code"] if detail.is_a?(Hash)
      return status.to_i if status.present?
    end

    match = message.match(HTTP_STATUS_IN_MESSAGE)
    match && match[1].to_i
  end

  # The reading to record against the account a quota refusal was about, or nil
  # for an error that is not one.
  #
  # Every refusal gets a reading, because the newest reading is what
  # QuotaResetCheckerJob (and the /inference heal) restore on, and it has to
  # describe the newest refusal — an older refusal's reading, long since reset,
  # would otherwise put the account straight back in rotation.
  #
  # The windows at their cap are marked refused with their reset times, so the
  # account comes back when those pass. A refusal the turn's reading does not
  # explain — no window at its cap, a capped window with no reset time, or no
  # windows at all because the backend sent no rate-limit headers — is recorded
  # as a refusal of the five-hour window with no reset: it never reads as clear,
  # so the account stays out of rotation until a human re-activates it.
  #
  # @return [QuotaReading, nil]
  def quota_reading
    return nil unless kind == :quota

    primary = window(rate_limits&.dig("primary"))
    secondary = window(rate_limits&.dig("secondary"))
    capped = [ primary, secondary ].compact.select { |w| w[:utilization].to_f >= 1.0 }

    if capped.empty? || capped.any? { |w| w[:reset].nil? }
      return QuotaReading.new(
        utilization_5h: primary&.dig(:utilization), reset_5h: nil, status_5h: REFUSED_STATUS,
        utilization_7d: secondary&.dig(:utilization), reset_7d: secondary&.dig(:reset), status_7d: nil
      )
    end

    QuotaReading.new(
      utilization_5h: primary&.dig(:utilization), reset_5h: primary&.dig(:reset),
      status_5h: capped.include?(primary) ? REFUSED_STATUS : nil,
      utilization_7d: secondary&.dig(:utilization), reset_7d: secondary&.dig(:reset),
      status_7d: capped.include?(secondary) ? REFUSED_STATUS : nil
    )
  end

  private

  def context_window_exceeded?
    return true if code == "context_window_exceeded"

    code == "other" && message.match?(CONTEXT_LENGTH_BODY_CODE)
  end

  # One rate-limit window as utilization (0.0–1.0) and reset time.
  def window(raw)
    return nil unless raw.is_a?(Hash)

    used = raw["used_percent"]
    resets_at = raw["resets_at"]
    {
      utilization: used.nil? ? nil : used.to_f / 100.0,
      reset: resets_at.is_a?(Numeric) ? Time.zone.at(resets_at) : nil
    }
  end
end
