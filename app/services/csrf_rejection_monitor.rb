# frozen_string_literal: true

# Turns a *rate* of CSRF rejections into a GlitchTip event, without turning every
# individual rejection into one.
#
# The distinction is the whole point, and it is issue #23's own framing: "One is
# noise; a hundred an hour means the app is broken." A single
# ActionController::InvalidAuthenticityToken is a stale form, a tab left open
# across a deploy, or a client POSTing at a real route without a token. A sustained
# stream of them is #19 — the app computing a scheme or host that differs from the
# one the browser sends (there, `assume_ssl` on a plain-HTTP tailnet deploy), so
# the Origin check fails *every write in the UI* for *every* real user. Production
# served exactly that, for hours, and nothing paged: sentry-rails excludes the
# class by default, so the one pipeline carrying the URL, verb and user agent
# dropped it client-side.
#
# ApplicationController#invalid_authenticity_token already re-logs each rejection
# at INFO with those fields (#295). That line does not leave the container — the
# OTLP exporter ships WARN and above — and it is per-record either way. This class
# is the counter on top of it:
#
#   * every rejection increments a counter in a tumbling WINDOW-length bucket;
#   * the first rejection to push a bucket to THRESHOLD reports ONE exception to
#     GlitchTip, carrying the count and the triage fields under a fixed
#     fingerprint, and emits ONE WARN so the same conclusion is reachable from
#     VictoriaLogs;
#   * every later rejection in that bucket is silent.
#
# So a storm costs at most one event and one WARN per WINDOW no matter how loud it
# gets, and the quiet base rate costs nothing at all.
#
# **A tumbling bucket, not a sliding window.** Ten rejections straddling a bucket
# boundary can split 6/4 and trip nothing. That is an accepted miss: the condition
# this exists to catch is not ten rejections, it is every write failing, which
# clears THRESHOLD several times over inside any single bucket. The alternative —
# a sorted set of timestamps per client — buys precision at a threshold that does
# not need it.
#
# **It fails closed on reporting, never open.** `Rails.cache` is Redis in
# production, and RedisCacheStore's `failsafe` rescues a connection error, hands it
# to the configured `error_handler` (which logs it at ERROR — so a dead Redis is
# loud on its own, here and on every other cache call) and returns nil rather than
# raising. The test env's `:null_store` also returns nil. Both mean "no counter",
# and no counter means no report — because the alternative, reporting every
# rejection when the counter is unavailable, is an unbounded flood into the alert
# path, which is the failure mode this whole issue is about. The per-record INFO
# line survives regardless.
#
# **It never breaks the response.** Everything here is wrapped: the caller is a
# `rescue_from` handler that still has a 422 to render, and a monitoring bug must
# not turn a client error into a 500.
class CsrfRejectionMonitor
  # Five minutes is short enough that a storm is reported while it is still
  # happening, and long enough that THRESHOLD means a rate rather than a burst.
  WINDOW = 5.minutes

  # 10 in 5 minutes is 120/hour sustained — the issue's "a hundred an hour" line,
  # and astronomically above the observed base rate: the 2026-08-02 triage found
  # the record that paged #alerts was the *first* InvalidAuthenticityToken in
  # production across the full 14-day VictoriaLogs retention window.
  #
  # Probe noise is a smaller risk than it looks. The catch-all route sends
  # unmatched paths to ErrorsController, which declares `skip_forgery_protection`,
  # so POSTs at invented paths raise nothing; to reach this counter a client has to
  # POST at *real* Zimmer routes, repeatedly. And on this deployment the host is
  # tailnet-only, so the clients that can do that at all are tailnet members.
  THRESHOLD = 10

  KEY_PREFIX = "csrf_rejection"

  # One GlitchTip issue for the rate signal, whatever the exception's stack. The
  # two surfaces without ApplicationController's rescue_from (/supervisor, /jobs)
  # report InvalidAuthenticityToken per request through the middleware, with the
  # same type, message and all-gem stack; without this, a storm's report could
  # land as one more event on an issue opened weeks earlier by a single stray POST.
  FINGERPRINT = [ "csrf-rejection-rate" ].freeze

  # @return [Symbol] what happened, for tests and for callers that want to log it:
  #   :reported, :already_reported, :below_threshold, or :not_counted.
  def self.record(exception, request:, session_cookie_present:)
    new(exception, request: request, session_cookie_present: session_cookie_present).record
  rescue StandardError => e
    # The one rescue boundary, and it is here rather than inside #record so that it
    # covers construction too. The caller is a `rescue_from` handler that still owes
    # the client a 422; a monitoring bug must never turn a client error into a 500.
    # ERROR, not WARN: nothing below is expected to raise (a dead Redis returns nil
    # rather than raising, and ErrorReporter swallows its own failures), so a raise
    # here is a defect in this file and should be as loud as one.
    Rails.logger.error("[CsrfRejectionMonitor] failed to evaluate the CSRF rejection rate: #{e.class}")
    :not_counted
  end

  def initialize(exception, request:, session_cookie_present:)
    @exception = exception
    @request = request
    @session_cookie_present = session_cookie_present
  end

  def record
    count = Rails.cache.increment(count_key, 1, expires_in: WINDOW * 2)
    return :not_counted if count.nil?
    return :below_threshold if count < THRESHOLD
    return :already_reported unless claim_window

    report(count)
    :reported
  end

  private

  # One report per bucket. `unless_exist` is atomic on both the Redis store and the
  # MemoryStore, so concurrent Puma threads crossing the threshold together still
  # produce exactly one event.
  def claim_window
    Rails.cache.write(report_key, true, expires_in: WINDOW * 2, unless_exist: true) == true
  end

  def report(count)
    # WARN, not ERROR: this record is meant to be *readable* in VictoriaLogs (the
    # exporter ships WARN and above), and the production Grafana rule counts ERROR
    # and FATAL. Paging is GlitchTip's job, on the event below. Deliberately one
    # line per window, so a storm cannot flood the log path either.
    Rails.logger.warn(
      "CSRF rejection rate exceeded: #{count} in #{WINDOW.to_i}s " \
      "(threshold #{THRESHOLD}) — latest #{@request.request_method} #{@request.path} " \
      "session_cookie=#{@session_cookie_present ? "present" : "absent"} " \
      "user_agent=#{@request.user_agent.to_s.inspect} " \
      "reason=#{@exception.message.to_s.inspect}"
    )

    # Reporting the exception object rather than a message is what makes the
    # initializer's un-exclusion load-bearing: Sentry::Client#event_from_exception
    # consults excluded_exceptions on an explicit capture exactly as it does on a
    # middleware one, so while "ActionController::InvalidAuthenticityToken" is in
    # the resolved list this call silently returns nil. It also gives GlitchTip a
    # real exception to group on, so a storm is one issue with N occurrences.
    #
    # No IP: `send_default_pii = false` is a deliberate decision in
    # config/initializers/sentry.rb (the SDK strips REMOTE_ADDR and X-Forwarded-For
    # from the request interface under it), and the fields that separate a stale
    # client from a misconfigured app are `session_cookie` and `reason`, not the
    # address. The per-record INFO line carries the IP for whoever needs it. Like
    # any request-scoped event, this one also carries the request's breadcrumbs,
    # including the rejected write's params after `filter_parameters`.
    ErrorReporter.report_exception(
      @exception,
      fingerprint: FINGERPRINT,
      context: {
        csrf_rejections_in_window: count,
        window_seconds: WINDOW.to_i,
        threshold: THRESHOLD,
        request_method: @request.request_method,
        path: @request.path,
        session_cookie: @session_cookie_present ? "present" : "absent",
        user_agent: @request.user_agent.to_s,
        reason: @exception.message.to_s
      }
    )
  end

  def count_key
    "#{KEY_PREFIX}:count:#{bucket}"
  end

  def report_key
    "#{KEY_PREFIX}:reported:#{bucket}"
  end

  # Memoized so the counter and the claim always name the same bucket: computed
  # twice, a boundary falling between the two would claim the NEXT bucket's report
  # slot early and suppress that bucket's report.
  def bucket
    @bucket ||= Time.current.to_i / WINDOW.to_i
  end
end
