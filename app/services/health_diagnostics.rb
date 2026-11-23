# frozen_string_literal: true

# The health report as the probes read it: bounded, with the facts they act on first.
#
# /health/export_diagnostics is polled every thirty seconds by the fleet-telemetry
# collector and the production deploy's worker soak, each giving up after fifteen. Both
# read `system_health` from it: the GoodJob heartbeat and the queues. When one section
# is slow that must not cost the probes the heartbeat, because a probe that gets no
# answer cannot tell a slow health page from a dead worker.
#
# So `system_health` is read first, on the request's own thread. It is never skipped and
# never served from an earlier reading; if it cannot be read, the whole report is
# Unreadable. Every other section is read after it, on a thread of its own, for
# BUDGET at most. A section that is not back by then, or that raises, is reported as not
# read, with an `unknown` status, rather than waited for.
#
# One section thread per process at a time. A read that outlives its budget keeps a
# database connection until it ends, so a probe every thirty seconds could otherwise
# stack them. While one is running, a report carries no section but the first.
class HealthDiagnostics
  CORE = :system_health

  # Read right after CORE: the monitoring plane scrapes it, and it is cheap.
  FIRST = %i[security_health cron_health].freeze

  # How long a request waits for the sections after CORE, comfortably inside the
  # probes' fifteen seconds.
  BUDGET = 6.seconds

  # No statement a report makes may outlast this, so that an abandoned section ends.
  STATEMENT_TIMEOUT = 4.seconds

  class Unreadable < StandardError; end

  class << self
    # @return [Boolean] whether the caller now owns this process's section thread
    def claim_sections_thread = sections_thread_busy.make_true

    def release_sections_thread = sections_thread_busy.make_false

    private

    def sections_thread_busy
      @sections_thread_busy ||= Concurrent::AtomicBoolean.new(false)
    end
  end
  # Built while the class loads, so two first requests cannot make two.
  sections_thread_busy

  def initialize(service: HealthMonitorService.new, budget: BUDGET, statement_timeout: STATEMENT_TIMEOUT)
    @service = service
    @budget = budget
    @statement_timeout = statement_timeout
    @timings = Concurrent::Map.new
    @read = Concurrent::Map.new
  end

  # @return [Hash] HealthMonitorService's report, plus `unread_sections` and
  #   `section_timings_ms`
  # @raise [Unreadable] when the queue and heartbeat facts cannot be read
  def report
    core = read_core
    read_sections
    # Copied once: a section thread that outlived its budget may still be writing.
    read = sections.index_with { |section| @read[section] || unread("Not read within #{@budget.to_i} seconds") }
    unread_sections = read.select { |_section, value| value[:unread] }.keys
    warn_unread(unread_sections) if unread_sections.any?

    ordered = HealthMonitorService::SECTIONS.index_with { |section| section == CORE ? core : read.fetch(section) }
    @service.assemble_report(ordered).merge(unread_sections: unread_sections, section_timings_ms: timings)
  end

  private

  def sections
    FIRST | (HealthMonitorService::SECTIONS - [ CORE ])
  end

  def read_core
    with_statement_timeout { timed(CORE) { @service.public_send(CORE) } }
  rescue StandardError => e
    # The class and not the message, which can carry connection detail.
    Rails.logger.warn("[HealthDiagnostics] #{CORE} could not be read: #{e.class}")
    raise Unreadable, "#{CORE} could not be read: #{e.class}"
  end

  def read_sections
    deadline = monotonic_now + @budget.to_f
    thread = start_sections_thread(deadline)
    return if thread.nil?

    ActiveSupport::Dependencies.interlock.permit_concurrent_loads { thread.join(@budget.to_f) }
  end

  def start_sections_thread(deadline)
    unless self.class.claim_sections_thread
      sections.each { |section| @read[section] = unread("An earlier report is still reading its sections") }
      return
    end

    begin
      Thread.new { read_each(deadline) }
    rescue StandardError
      self.class.release_sections_thread
      raise
    end
  end

  def read_each(deadline)
    Thread.current.report_on_exception = false
    Rails.application.executor.wrap do
      with_statement_timeout do
        sections.each do |section|
          break if monotonic_now >= deadline

          @read[section] = read_section(section)
        end
      end
    end
  rescue StandardError => e
    Rails.logger.warn("[HealthDiagnostics] sections could not be read: #{e.class}")
  ensure
    self.class.release_sections_thread
  end

  def read_section(section)
    timed(section) { @service.public_send(section) }
  rescue StandardError => e
    unread("Could not be read: #{e.class}")
  end

  # `error` is what the collector reads as "no counts" in security_health.
  def unread(reason)
    {
      unread: true, error: reason,
      status: HealthMonitorService::HealthStatus.new(status: :unknown, message: reason)
    }
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
    pool = ActiveRecord::Base.connection_pool
    pool.with_connection do |connection|
      connection.execute("SET statement_timeout = #{Integer((@statement_timeout * 1000).ceil)}")
      yield
    ensure
      begin
        connection.execute("SET statement_timeout = DEFAULT")
      rescue ActiveRecord::ActiveRecordError
        # A connection that cannot be reset must not go back to the pool with the limit on.
        pool.remove(connection)
      end
    end
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
