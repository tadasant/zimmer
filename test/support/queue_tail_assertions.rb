# frozen_string_literal: true

# The captured-SQL proof that a queue writer reads its position through
# Sessions::QueueTail: `SELECT … FOR NO KEY UPDATE` on the session first, then
# `MAX(position)`, then the `INSERT`, with no COMMIT or savepoint release in
# between that would drop the lock before the row lands.
module QueueTailAssertions
  def assert_appends_under_queue_tail_lock
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql]
    end

    begin
      yield
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    lock_index = statements.index { |sql| sql.include?('FROM "sessions"') && sql.include?("FOR NO KEY UPDATE") }
    assert lock_index, "expected a SELECT ... FOR NO KEY UPDATE on the session"
    max_index = statements.index.with_index { |sql, i| i > lock_index && sql.include?("MAX(") && sql.include?("enqueued_messages") }
    assert max_index, "expected the MAX(position) read after the lock"
    insert_index = statements.index.with_index { |sql, i| i > max_index && sql.start_with?('INSERT INTO "enqueued_messages"') }
    assert insert_index, "expected the INSERT after the tail read"
    assert_not statements[lock_index..insert_index].any? { |sql| sql.start_with?("RELEASE SAVEPOINT", "COMMIT") },
      "the lock must still be held when the row is inserted"
    assert_not statements[0...lock_index].any? { |sql| sql.include?("MAX(") && sql.include?("enqueued_messages") },
      "the tail must not be read before the lock is taken"
  end
end
