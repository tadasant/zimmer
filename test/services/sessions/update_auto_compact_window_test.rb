require "test_helper"

class Sessions::UpdateAutoCompactWindowTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:needs_input)
    @session.update!(auto_compact_window: 400_000)
  end

  test "sets the window and logs the change" do
    Sessions::UpdateAutoCompactWindow.call(session: @session, auto_compact_window: 500_000, actor: :web)

    assert_equal 500_000, @session.reload.auto_compact_window
    assert_equal "Context window updated (400000 → 500000); applies on next turn or restart",
      @session.logs.order(:created_at).last.content
  end

  test "accepts a string of digits and labels the MCP log row" do
    Sessions::UpdateAutoCompactWindow.call(session: @session, auto_compact_window: "250000", actor: :mcp)

    assert_equal 250_000, @session.reload.auto_compact_window
    assert_equal "Context window updated via MCP (400000 → 250000); applies on next turn or restart",
      @session.logs.order(:created_at).last.content
  end

  test "the window the session already has is a no-op" do
    assert_no_difference -> { @session.logs.count } do
      Sessions::UpdateAutoCompactWindow.call(session: @session, auto_compact_window: 400_000, actor: :web)
    end
  end

  test "a retry after a failed write still writes the window" do
    # A failed UPDATE leaves the new window on the in-memory record; the retry
    # must compare against what is stored, not short-circuit as a no-op.
    @session.auto_compact_window = 500_000

    Sessions::UpdateAutoCompactWindow.call(session: @session, auto_compact_window: 500_000, actor: :web)

    assert_equal 500_000, @session.reload.auto_compact_window
    assert_equal "Context window updated (400000 → 500000); applies on next turn or restart",
      @session.logs.order(:created_at).last.content
  end

  test "refuses a missing, blank or non-integer value and writes nothing" do
    [ nil, "", "abc", "5.5", "-5", 5.5 ].each do |value|
      error = assert_raises(Sessions::UpdateAutoCompactWindow::InvalidParameter, "#{value.inspect} should be refused") do
        Sessions::UpdateAutoCompactWindow.call(session: @session, auto_compact_window: value, actor: :web)
      end
      assert_equal "auto_compact_window must be a positive integer", error.message
    end
    assert_equal 400_000, @session.reload.auto_compact_window
  end

  test "refuses an integer outside the bounds and writes nothing" do
    [ 0, "0", Session::MAX_AUTO_COMPACT_WINDOW + 1 ].each do |value|
      error = assert_raises(Sessions::UpdateAutoCompactWindow::OutOfRange, "#{value.inspect} should be refused") do
        Sessions::UpdateAutoCompactWindow.call(session: @session, auto_compact_window: value, actor: :web)
      end
      assert_equal "auto_compact_window must be between 1 and #{Session::MAX_AUTO_COMPACT_WINDOW}", error.message
    end
    assert_equal 400_000, @session.reload.auto_compact_window
  end

  test "accepts both bounds" do
    Sessions::UpdateAutoCompactWindow.call(session: @session, auto_compact_window: 1, actor: :web)
    assert_equal 1, @session.reload.auto_compact_window

    Sessions::UpdateAutoCompactWindow.call(session: @session, auto_compact_window: Session::MAX_AUTO_COMPACT_WINDOW, actor: :web)
    assert_equal Session::MAX_AUTO_COMPACT_WINDOW, @session.reload.auto_compact_window
  end

  test "the write and the log row land together" do
    logs = @session.logs
    @session.stub(:logs, logs) do
      logs.stub(:create!, ->(*) { raise ActiveRecord::StatementInvalid, "boom" }) do
        assert_raises(ActiveRecord::StatementInvalid) do
          Sessions::UpdateAutoCompactWindow.call(session: @session, auto_compact_window: 500_000, actor: :web)
        end
      end
    end

    assert_equal 400_000, @session.reload.auto_compact_window
  end
end
