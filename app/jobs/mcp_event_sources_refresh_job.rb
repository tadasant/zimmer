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

  # Servers asked at once. Most sit behind one gateway, which should not see the whole catalog land
  # in the same second.
  CONCURRENCY = 4

  def perform
    queue = Queue.new
    McpEvents::Sources.candidates.each { |server| queue << server.name }
    found = Concurrent::Array.new

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
            found << source if source
          end
        end
      end
    end
    workers.each(&:join)

    McpEvents::Sources.write_roster!(found.sort_by(&:server_name))
    Rails.logger.info "[McpEventSourcesRefreshJob] #{found.size} server(s) publish events: #{found.map(&:server_name).join(', ').presence || 'none'}"
  end

  private

  def probe(name)
    McpEvents::Sources.probe(name, cache: false)
  rescue McpEvents::Sources::Unavailable, StandardError => e
    Rails.logger.info "[McpEventSourcesRefreshJob] #{name}: #{e.message}"
    nil
  end
end
