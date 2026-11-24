# frozen_string_literal: true

# A section thread a test abandons still shares the test's pinned connection, so it has to
# be gone before that connection is used for anything else.
module HealthDiagnosticsHelpers
  def wait_for_sections_thread
    acquired = HealthDiagnostics::SECTIONS_THREAD.try_acquire(1, 10)
    flunk "the section thread never finished" unless acquired
    HealthDiagnostics::SECTIONS_THREAD.release
  end

  def monotonic_timed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    [ result, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started ]
  end

  # A section body that announces it has been reached and then blocks until released.
  class Hang
    def initialize
      @reached = Queue.new
      @release = Queue.new
    end

    def call
      @reached << true
      @release.pop
      {}
    end

    def wait_until_reached = @reached.pop(timeout: 10) || raise("the section was never reached")
    def release = @release.close
  end
end
