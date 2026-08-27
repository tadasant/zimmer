# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class Sessions::IdempotentCreateTest < ActiveSupport::TestCase
  def build(key: nil, **overrides)
    Session.new({
      git_root: "https://github.com/test/repo.git",
      prompt: "work",
      idempotency_key: key
    }.merge(overrides))
  end

  test "a blank key means a plain create" do
    assert_nil Sessions::IdempotentCreate.existing(nil)
    assert_nil Sessions::IdempotentCreate.existing("")

    result = nil
    assert_difference "Session.count", 1 do
      result = Sessions::IdempotentCreate.save(build, nil)
    end

    assert result.created?
    refute result.reused?
    assert_nil result.session.idempotency_key
  end

  test "existing finds the session a key already created" do
    session = build(key: "k1")
    assert session.save

    assert_equal session.id, Sessions::IdempotentCreate.existing("k1").id
    assert_nil Sessions::IdempotentCreate.existing("k2")
  end

  # The sequential retry, at the model layer: the winner has committed by the
  # time the loser validates, so the uniqueness validation is what refuses it.
  test "a save whose key was taken between the lookup and the write returns the winner" do
    winner = build(key: "raced", title: "First")
    assert winner.save

    loser = build(key: "raced", title: "Second")
    result = nil
    assert_no_difference "Session.count" do
      result = Sessions::IdempotentCreate.save(loser, "raced")
    end

    assert result.reused?
    assert_equal winner.id, result.session.id
    assert_equal "First", result.session.title, "the winner's session is returned, not the loser's attributes"
  end

  # The concurrent retry: the winner commits while the loser's INSERT is already
  # waiting on the unique index, so Postgres refuses it and no validation ever
  # sees the conflict. Simulated rather than raced, because a real race needs two
  # connections; the point under test is that this exception is interpreted, not
  # that Postgres raises it.
  test "a RecordNotUnique on the idempotency key returns the winner rather than raising" do
    winner = build(key: "concurrent", title: "First")
    assert winner.save

    loser = build(key: "concurrent", title: "Second")
    loser.stubs(:save).raises(ActiveRecord::RecordNotUnique, "duplicate key value violates unique constraint")

    result = Sessions::IdempotentCreate.save(loser, "concurrent")

    assert result.reused?
    assert_equal winner.id, result.session.id
  end

  # A unique violation on some other column is still an error. Swallowing it
  # would turn a duplicate slug into a silent, wrong "here is your session".
  test "a RecordNotUnique that is not about the key is re-raised" do
    session = build(key: "unheld")
    session.stubs(:save).raises(ActiveRecord::RecordNotUnique, "duplicate key value violates unique constraint \"index_sessions_on_slug\"")

    assert_raises(ActiveRecord::RecordNotUnique) do
      Sessions::IdempotentCreate.save(session, "unheld")
    end
  end

  test "a save that fails for an ordinary validation reason returns nil and keeps its errors" do
    invalid = build(key: "k3", git_root: nil)

    assert_nil Sessions::IdempotentCreate.save(invalid, "k3")
    assert_includes invalid.errors.full_messages.join, "Git root"
  end

  test "the database refuses a duplicate key even when the model validation is skipped" do
    build(key: "db-enforced").save!

    # requires_new so the violation rolls back a savepoint rather than poisoning
    # the test's own transaction, which would take the rest of the case with it.
    assert_raises(ActiveRecord::RecordNotUnique) do
      Session.transaction(requires_new: true) { build(key: "db-enforced").save!(validate: false) }
    end
  end

  test "any number of sessions may carry no key at all" do
    assert_difference "Session.count", 3 do
      3.times { build.save! }
    end
  end
end
