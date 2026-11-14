# frozen_string_literal: true

require "test_helper"

# The race Sessions::QueueTail exists to close, run on two real connections.
#
# One connection appends through QueueTail and holds its transaction open with
# the row uncommitted. A second writer appends to the same session meanwhile.
# Reading `maximum(:position)` without the lock, the second writer reads the
# same tail, and the deferred `(session_id, position)` unique constraint fails
# one of them at COMMIT. Reading through QueueTail, it waits for the first to
# commit and lands at the next position.
#
# Non-transactional deliberately: the question is what one connection sees of
# another's uncommitted work, and a transactional test hides exactly that.
class Sessions::QueueTailConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @session = Session.create!(
      prompt: "Original prompt",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      session_id: SecureRandom.uuid,
      status: :running
    )
  end

  teardown do
    @session&.destroy
  end

  test "an MCP App widget message waits for an open append and queues behind it" do
    second = race { |session| McpApps::WidgetMessage.deliver(session: session, server_name: "notion", tool: "open_panel", text: "second", kind: "context") }

    assert_equal :queued, second.status
    assert_queued_in_order(2)
  end

  test "a skipped job's prompt waits for an open append and queues behind it" do
    second = race { |session| Sessions::RequeueSkippedPrompt.call(session, prompt: "The skipped job's prompt") }

    assert_equal :queued, second
    assert_queued_in_order(2)
  end

  private

  # Holds an append open on one connection, runs the block on another, asserts
  # the block is blocked behind the lock, then commits the first append and
  # returns what the block returned.
  def race(&writer)
    holding = Queue.new
    release = Queue.new
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          session = Session.find(@session.id)
          session.enqueued_messages.create!(
            content: "first", status: "pending", position: Sessions::QueueTail.next_position!(session)
          )
          holding << true
          release.pop
        end
      end
    end
    holding.pop

    finished = Queue.new
    contender = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        finished << writer.call(Session.find(@session.id))
      end
    end

    sleep 0.3
    assert finished.empty?, "the second writer must wait while another append holds the queue tail"

    release << true
    holder.join(10)
    contender.join(10)
    finished.pop(true)
  end

  def assert_queued_in_order(count)
    positions = @session.enqueued_messages.order(:position).pluck(:content, :position)
    assert_equal count, positions.size, "both appends must land: #{positions.inspect}"
    assert_equal "first", positions.first.first
    assert_equal (1..count).to_a, positions.map(&:last)
  end
end
