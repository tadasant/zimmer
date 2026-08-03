# frozen_string_literal: true

# Captures (severity, message) pairs from every Rails.logger write during a block,
# including writes from Rack middleware.
#
# It attaches a sink to the existing logger object rather than assigning
# Rails.logger, and that distinction is load-bearing rather than stylistic. Rails
# hands out references to the logger in several places, and an assignment is
# invisible to all of them. The one that matters most:
# Rails::Application#env_config memoizes "action_dispatch.logger" => Rails.logger
# the first time anything asks for it, and Rails::Engine#build_request merges that
# hash *over* every request env — so the logger ActionDispatch::DebugExceptions
# writes an unhandled exception to is fixed for the life of the process and cannot
# be overridden per request. A capture that assigns Rails.logger therefore sees
# strictly less than one that broadcasts, and what it misses is precisely the
# ERROR records a logging test usually exists to assert on. See issue #337, and
# the env_config pin in test_helper.rb that keeps that entry pointing at the real
# boot logger in every parallel worker.
#
# Assigning Rails.logger around a request is also what poisoned that memo in the
# first place, which is why test/contracts/log_capture_contract_test.rb forbids it
# in any test that can issue one.
module LogCaptureHelpers
  def capture_log_entries
    sink = RecordingLogger.new
    Rails.logger.broadcast_to(sink)

    yield

    sink.entries
  ensure
    Rails.logger.stop_broadcasting_to(sink)
  end

  # Records severity alongside the message so assertions can test the severity a
  # log alert actually counts, rather than regexing a formatted line — a message
  # body is free to contain the word "ERROR" at any severity.
  class RecordingLogger < ::Logger
    attr_reader :entries

    def initialize
      super(nil)
      self.level = ::Logger::DEBUG
      @entries = []
    end

    def add(severity, message = nil, progname = nil, &block)
      severity ||= ::Logger::UNKNOWN
      resolved = message || (block ? block.call : progname)
      @entries << [ format_severity(severity), resolved.to_s ]

      super
    end
  end
end
