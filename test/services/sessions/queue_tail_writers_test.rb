# frozen_string_literal: true

require "test_helper"

# Every writer that appends to a session's queue reads its position through
# Sessions::QueueTail. A writer that reads `maximum(:position)` on its own is not
# ordered by the session row lock, so it can read the same tail as a QueueTail
# caller and lose the deferred `(session_id, position)` unique constraint at
# COMMIT. This fails on a new one before it ships. It matches the spelling
# every writer has used, `maximum(:position)`; it does not catch other ways of
# reading the tail (`pluck(:position).max`, `order(position: :desc).first`).
class Sessions::QueueTailWritersTest < ActiveSupport::TestCase
  QUEUE_TAIL = "app/services/sessions/queue_tail.rb"

  test "no queue writer in app/ reads the tail position outside Sessions::QueueTail" do
    offenders = Dir[Rails.root.join("app/**/*.rb")].flat_map do |path|
      relative = Pathname(path).relative_path_from(Rails.root).to_s
      next [] if relative == QUEUE_TAIL

      File.readlines(path).each_with_index.filter_map do |line, index|
        next if line.lstrip.start_with?("#")

        "#{relative}:#{index + 1}" if line.match?(/maximum\(\s*:position\s*\)/)
      end
    end

    assert_empty offenders,
      "Read a queue position with Sessions::QueueTail.next_position!(session), inside the transaction " \
      "that inserts the row, instead of `maximum(:position)`:\n#{offenders.join("\n")}"
  end
end
