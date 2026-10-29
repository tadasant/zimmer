# frozen_string_literal: true

require "test_helper"

class Sessions::UpdatePrecedenceTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:needs_input)
    @session.update!(scheduling_class: SessionGenesis::SPOT, precedence: 10)
  end

  test "sets the rank and logs the move" do
    result = Sessions::UpdatePrecedence.call(session: @session, precedence: 640, actor: :web)

    assert_equal 640, @session.reload.precedence
    assert_equal 10, result.previous
    assert_equal 640, result.precedence
    assert result.changed?
    assert_equal "Precedence set to 640 (was 10)", @session.logs.order(:created_at).last.content
  end

  test "accepts a string of digits and labels the MCP log row" do
    Sessions::UpdatePrecedence.call(session: @session, precedence: "55", actor: :mcp)

    assert_equal 55, @session.reload.precedence
    assert_equal "Precedence set via MCP to 55 (was 10)", @session.logs.order(:created_at).last.content
  end

  test "the rank the session already has writes no log row" do
    result = nil
    assert_no_difference -> { @session.logs.count } do
      result = Sessions::UpdatePrecedence.call(session: @session, precedence: 10, actor: :web)
    end
    assert_not result.changed?
    assert_equal 10, result.previous
  end

  test "a blank value is the model's say-nothing, which is the default" do
    Sessions::UpdatePrecedence.call(session: @session, precedence: "", actor: :web)

    assert_equal SessionPrecedence::DEFAULT, @session.reload.precedence
    assert_equal "Precedence set to #{SessionPrecedence::DEFAULT} (was 10)", @session.logs.order(:created_at).last.content
  end

  test "a retry after a failed write still logs the move" do
    # A failed UPDATE leaves the new rank on the in-memory record; the retry must
    # compare against what is stored, not read it as a no-op.
    @session.precedence = 640

    result = Sessions::UpdatePrecedence.call(session: @session, precedence: 640, actor: :web)

    assert_equal 10, result.previous
    assert_equal "Precedence set to 640 (was 10)", @session.logs.order(:created_at).last.content
  end

  test "refuses a value the model refuses and writes nothing" do
    [ SessionPrecedence::MAX + 1, SessionPrecedence::MIN - 1, "urgent", "5.5" ].each do |value|
      assert_no_difference -> { @session.logs.count } do
        assert_raises(ActiveRecord::RecordInvalid, "#{value.inspect} should be refused") do
          Sessions::UpdatePrecedence.call(session: @session, precedence: value, actor: :web)
        end
      end
      assert_includes @session.errors.full_messages.join, "Precedence"
      assert_equal 10, @session.reload.precedence
    end
  end

  test "touches only the rank" do
    Sessions::UpdatePrecedence.call(session: @session, precedence: 900, actor: :mcp)

    @session.reload
    assert_equal SessionGenesis::SPOT, @session.scheduling_class
    assert @session.needs_input?
  end

  test "labels the REST log row" do
    Sessions::UpdatePrecedence.call(session: @session, precedence: 70, actor: :rest)

    assert_equal "Precedence set via the REST API to 70 (was 10)", @session.logs.order(:created_at).last.content
  end

  test "a caller that owns the save passes a block, and its assigned columns ride along" do
    @session.slug = "ridden-along"
    saves = 0

    result = Sessions::UpdatePrecedence.call(session: @session, precedence: 300, actor: :rest) do
      saves += 1
      @session.save!
    end

    assert_equal 1, saves
    assert result.changed?
    @session.reload
    assert_equal 300, @session.precedence
    assert_equal "ridden-along", @session.slug
    assert_equal "Precedence set via the REST API to 300 (was 10)", @session.logs.order(:created_at).last.content
  end
end
