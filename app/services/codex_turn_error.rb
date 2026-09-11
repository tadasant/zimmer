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
# account once it passes.
class CodexTurnError
  # The rollout records that say a turn started or stopped. The LAST of them
  # decides whether there is a terminal error at all: a `task_started` after the
  # last `task_complete` is a turn that has not ended (or died without Codex
  # writing how), and it is not the earlier turn's error that it died on.
  TURN_LIFECYCLE_EVENTS = %w[task_started task_complete turn_aborted].freeze

  # Codex codes that are a transient upstream failure — the same class as a
  # Claude 5xx / overloaded error.
  RETRYABLE_CODES = %w[internal_server_error server_overloaded].freeze

  # `unexpected status 503 …` / `exceeded retry limit, last status: 429 …` — the
  # two forms Codex puts an HTTP status into prose with, used when the code is
  # the catch-all `other`.
  HTTP_STATUS_IN_MESSAGE = /\b(?:unexpected status|last status:)\s+(\d{3})\b/

  # The API's own error code, passed through verbatim when Codex surfaces a raw
  # 400 body under `other`.
  CONTEXT_LENGTH_BODY_CODE = /"code"\s*:\s*"context_length_exceeded"/

  # The quota reading this turn left behind, in the shape
  # QuotaSnapshotService.save_snapshot takes (QuotaCheckService::Result's
  # fields). Codex's primary window lands in the columns Claude's five-hour
  # window uses and its secondary window in the weekly ones;
  # ClaudeAccountQuotaSnapshot#windows_clear? — what the restore decides on —
  # asks about reset times and counters, not window lengths.
  QuotaReading = Data.define(:utilization_5h, :reset_5h, :utilization_7d, :reset_7d) do
    def subscription_type = nil
    def rate_limit_tier = nil
    def status_5h = nil
    def status_7d = nil
    def overage_status = nil
    def overage_disabled_reason = nil

    # When the account can serve again: the latest reset among the windows at
    # their cap, which is when ClaudeAccountQuotaSnapshot#windows_clear? turns true.
    def restores_at
      [ [ utilization_5h, reset_5h ], [ utilization_7d, reset_7d ] ]
        .filter_map { |utilization, reset| reset if utilization.to_f >= 1.0 }
        .max
    end
  end

  attr_reader :message, :info, :turn_id, :line, :rate_limits

  # The terminal turn error in a serialized rollout, or nil when the latest turn
  # did not end on one.
  #
  # @param serialized [String, nil] the rollout's JSONL
  # @return [CodexTurnError, nil]
  def self.terminal(serialized)
    return nil if serialized.blank?

    last_lifecycle = nil
    rate_limits = nil

    serialized.each_line.with_index(1) do |raw, line_number|
      next if raw.strip.empty?

      record = begin
        JSON.parse(raw)
      rescue JSON::ParserError
        next
      end
      next unless record.is_a?(Hash) && record["type"] == "event_msg"

      payload = record["payload"]
      next unless payload.is_a?(Hash)

      if payload["type"] == "token_count"
        limits = payload["rate_limits"]
        rate_limits = limits if limits.is_a?(Hash) && (limits["primary"].is_a?(Hash) || limits["secondary"].is_a?(Hash))
      elsif TURN_LIFECYCLE_EVENTS.include?(payload["type"])
        last_lifecycle = [ payload, line_number ]
      end
    end

    return nil unless last_lifecycle

    payload, line_number = last_lifecycle
    error = payload["error"]
    return nil unless payload["type"] == "task_complete" && error.is_a?(Hash)

    new(
      message: error["message"].to_s,
      info: error["codex_error_info"],
      turn_id: payload["turn_id"].presence,
      line: line_number,
      rate_limits: rate_limits
    )
  end

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

  # The reading to record against the account this turn ran as, or nil when the
  # reading Codex recorded does not say when the account comes back.
  #
  # It has to explain the refusal: at least one window at its cap, and every
  # capped window with a reset time. Anything less is refused rather than
  # recorded, because recorded it would read as clear —
  # ClaudeAccountQuotaSnapshot counts a window under its cap, or one whose reset
  # is unknown, as clear — and QuotaResetCheckerJob would put an account that
  # was just refused straight back in rotation. That covers a refusal that came
  # with no rate-limit headers at all, where the latest reading is one an
  # earlier, successful turn left behind.
  #
  # @return [QuotaReading, nil]
  def quota_reading
    return nil unless rate_limits.is_a?(Hash)

    primary = window(rate_limits["primary"])
    secondary = window(rate_limits["secondary"])
    capped = [ primary, secondary ].compact.select { |w| w[:utilization].to_f >= 1.0 }
    return nil if capped.empty?
    return nil if capped.any? { |w| w[:reset].nil? }

    QuotaReading.new(
      utilization_5h: primary&.dig(:utilization),
      reset_5h: primary&.dig(:reset),
      utilization_7d: secondary&.dig(:utilization),
      reset_7d: secondary&.dig(:reset)
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
