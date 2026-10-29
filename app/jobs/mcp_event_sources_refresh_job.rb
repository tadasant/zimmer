# frozen_string_literal: true

# Sweeps the catalog's remote MCP servers for the ones that publish events (McpEvents::Sources), so
# the trigger form and list_mcp_event_sources can offer them without asking every server on every
# render.
#
# One `initialize` per remote server, and an `events/list` for each that declares the extension —
# a few seconds of requests, every six hours. A server that cannot be asked is left out of the
# roster and logged; it costs nothing else, and a condition already pointed at it keeps polling.
class McpEventSourcesRefreshJob < ApplicationJob
  queue_as :default

  # One sweep at a time: a congested queue must not stack copies that ask every server again.
  include SingletonSweep

  # Servers asked at once. Most sit behind one gateway, which should not see the whole catalog land
  # in the same second.
  CONCURRENCY = 4

  def perform
    queue = Queue.new
    McpEvents::Sources.candidates.each { |server| queue << server.name }
    found = Concurrent::Array.new
    failed = Concurrent::AtomicFixnum.new

    workers = Array.new(CONCURRENCY) do
      Thread.new do
        Rails.application.executor.wrap do
          loop do
            name = begin
              queue.pop(true)
            rescue ThreadError
              break
            end
            source = probe(name)
            if source == :failed
              failed.increment
            elsif source
              found << source
            end
          end
        end
      end
    end
    workers.each(&:join)

    # Every server failing at once is an outage — strad down, the network gone — not a catalog with
    # no events in it. Keep the last roster rather than empty the form's suggestions for six hours.
    if found.empty? && failed.value.positive? && McpEvents::Sources.roster.any?
      Rails.logger.warn "[McpEventSourcesRefreshJob] no server answered with events and #{failed.value} could not be asked; keeping the previous roster"
      return
    end

    McpEvents::Sources.write_roster!(found.sort_by(&:server_name))
    Rails.logger.info "[McpEventSourcesRefreshJob] #{found.size} server(s) publish events: #{found.map(&:server_name).join(', ').presence || 'none'}"
  end

  private

  # A Source, nil (the server answered and publishes no events), or :failed (it could not be asked).
  def probe(name)
    McpEvents::Sources.probe(name, cache: false)
  rescue StandardError => e
    Rails.logger.info "[McpEventSourcesRefreshJob] #{name}: #{e.message}"
    :failed
  end
end
