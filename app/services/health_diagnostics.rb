# frozen_string_literal: true

# The health report as the probes read it: bounded, with the facts they act on first.
#
# /health/export_diagnostics is polled every thirty seconds by the fleet-telemetry
# collector and the production deploy's worker soak, each giving up after fifteen. Both
# read `system_health` from it: the GoodJob heartbeat and the queues. When one section
# is slow that must not cost the probes the heartbeat, because a probe that gets no
# answer cannot tell a slow health page from a dead worker.
#
# So those facts (HealthMonitorService#queue_health) are read first, on the request's own
# thread. They are never skipped and never served from an earlier reading; if they cannot
# be read, the whole report is Unreadable. Everything else is read after, on a thread of
# its own, for BUDGET at most. What is not back by then, or raises, is reported as not
# read, with an `unknown` status, rather than waited for.
#
# One section thread per process at a time. A read that outlives its budget keeps a
# database connection until it ends, so a probe every thirty seconds could otherwise
# stack them. A report that finds one running waits for it, inside its own budget.
class HealthDiagnostics
  CORE = :system_health

  # `system_health.recent_errors`, which no probe reads, so it is read like a section.
  RECENT_ERRORS = :recent_errors

  # Read right after CORE: the monitoring plane scrapes it, and it is cheap.
  FIRST = %i[security_health cron_health].freeze

  # How long a request waits for what comes after CORE.
  BUDGET = 6.seconds

  # How old a request may be and still wait, so that a slow CORE comes out of BUDGET
  # rather than on top of it. Inside the probes' fifteen seconds.
  TOTAL = 12.seconds

  # No statement a report makes may outlast this, so that an abandoned section ends.
  STATEMENT_TIMEOUT = 4.seconds

  SECTIONS_THREAD = Concurrent::Semaphore.new(1)

  class Unreadable < StandardError; end

  def initialize(service: HealthMonitorService.new(raise_unreadable: true),
                 budget: BUDGET, total: TOTAL, statement_timeout: STATEMENT_TIMEOUT)
    @service = service
    @budget = budget.to_f
    @total = total.to_f
    @statement_timeout = statement_timeout.to_f
    @timings = Concurrent::Map.new
    @read = Concurrent::Map.new
    @started = monotonic_now
  end

  # @return [Hash] HealthMonitorService's report, plus `unread_sections` and
  #   `section_timings_ms`
  # @raise [Unreadable] when the queue and heartbeat facts cannot be read
  def report
    core = read_core
    read_sections
    # Copied once: a section thread that outlived its budget may still be writing.
    read = sections.index_with { |section| @read[section] || unread("Not read in time") }
    unread_sections = read.select { |_section, value| unread?(value) }.keys
    warn_unread(unread_sections) if unread_sections.any?

    assemble(core, read).merge(unread_sections: unread_sections, section_timings_ms: timings)
  end

  private

  def sections
    FIRST | (HealthMonitorService::SECTIONS - [ CORE ]) | [ RECENT_ERRORS ]
  end

  def assemble(core, read)
    errors = read.fetch(RECENT_ERRORS)
    # Absent rather than empty: an empty list says no error was recorded.
    core = core.merge(recent_errors: unread?(errors) ? nil : errors)
    ordered = HealthMonitorService::SECTIONS.index_with { |section| section == CORE ? core : read.fetch(section) }
    report = @service.assemble_report(ordered)

    unread_checks = HealthMonitorService::OVERALL_STATUS_SECTIONS.count { |section| unread?(ordered[section]) }
    return report if unread_checks.zero? || !report[:overall_status].healthy?

    # `healthy` over checks that were not made would be a pass nobody gave.
    report.merge(overall_status: HealthMonitorService::HealthStatus.new(
      status: :unknown,
      message: "No issues detected, but #{unread_checks} of " \
               "#{HealthMonitorService::OVERALL_STATUS_SECTIONS.size} checks could not be read"
    ))
  end

  def read_core
    with_statement_timeout { timed(CORE) { @service.queue_health } }
  rescue StandardError => e
    # The class and not the message, which can carry connection detail.
    Rails.logger.warn("[HealthDiagnostics] #{CORE} could not be read: #{e.class}")
    raise Unreadable, "#{CORE} could not be read: #{e.class}"
  end

  def read_sections
    deadline = [ monotonic_now + @budget, @started + @total ].min
    release_connection
    if SECTIONS_THREAD.try_acquire(1, [ deadline - monotonic_now, 0 ].max)
      start_sections_thread(deadline)&.join([ deadline - monotonic_now, 0 ].max)
    else
      sections.each { |section| @read[section] = unread("An earlier report is still reading its sections") }
    end
  end

  # The section thread needs a connection, and this thread needs none while it waits.
  def release_connection
    pool = ActiveRecord::Base.connection_pool
    pool.release_connection unless pool.active_connection? && pool.lease_connection.transaction_open?
  end

  def start_sections_thread(deadline)
    Thread.new { read_each(deadline) }
  rescue StandardError => e
    SECTIONS_THREAD.release
    mark_rest_unread(e)
    nil
  end

  # Exception and not StandardError: what a thread dies of is re-raised in the request
  # that joins it, and nothing in a section may cost the request its heartbeat.
  def read_each(deadline)
    Thread.current.report_on_exception = false
    Rails.application.executor.wrap do
      with_statement_timeout do
        sections.each do |section|
          break if monotonic_now >= deadline

          @read[section] = read_section(section)
        end
      end
    rescue Exception => e # rubocop:disable Lint/RescueException
      mark_rest_unread(e)
    end
  ensure
    SECTIONS_THREAD.release
  end

  def read_section(section)
    timed(section) { @service.public_send(section == RECENT_ERRORS ? :recent_error_logs : section) }
  rescue Exception => e # rubocop:disable Lint/RescueException
    unread("Could not be read: #{e.class}")
  end

  def mark_rest_unread(error)
    sections.each { |section| @read[section] ||= unread("Could not be read: #{error.class}") }
  end

  # `error` is what the collector reads as "no counts" in security_health.
  def unread(reason)
    {
      unread: true, error: reason,
      status: HealthMonitorService::HealthStatus.new(status: :unknown, message: reason)
    }
  end

  def unread?(value)
    value.is_a?(Hash) && value[:unread] == true
  end

  def warn_unread(unread_sections)
    Rails.logger.warn(
      "[HealthDiagnostics] answered without #{unread_sections.join(", ")} (timings ms: #{timings.to_json})"
    )
  end

  def timings
    @timings.each_pair.to_h
  end

  def timed(section)
    started = monotonic_now
    yield
  ensure
    @timings[section] = ((monotonic_now - started) * 1000).round
  end

  # Per connection rather than per transaction: a section makes its own transactions, and
  # one that is cancelled must not abort the statements after it.
  def with_statement_timeout
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      connection.execute("SET statement_timeout = #{Integer((@statement_timeout * 1000).ceil)}")
      yield
    ensure
      begin
        connection.execute("SET statement_timeout = DEFAULT")
      rescue ActiveRecord::ActiveRecordError
        # A connection that cannot be reset must not go back to the pool with the limit on.
        connection.throw_away!
      end
    end
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
