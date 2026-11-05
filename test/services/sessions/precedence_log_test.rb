# frozen_string_literal: true

require "test_helper"

class Sessions::PrecedenceLogTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:needs_input)
    @session.update!(precedence: 55)
    @session.logs.delete_all
  end

  test "writes the row at info level" do
    row = Sessions::PrecedenceLog.write(@session, previous: 10, label: " via MCP")

    assert_equal "Precedence set via MCP to 55 (was 10)", row.content
    assert_equal "info", row.level
    assert_equal [ row ], @session.logs.to_a
  end

  test "an empty label reads without a gap" do
    row = Sessions::PrecedenceLog.write(@session, previous: 10, label: "")

    assert_equal "Precedence set to 55 (was 10)", row.content
  end

  test "a rank that did not move writes no row" do
    assert_nil Sessions::PrecedenceLog.write(@session, previous: 55, label: " via MCP")
    assert_empty @session.logs
  end
end
