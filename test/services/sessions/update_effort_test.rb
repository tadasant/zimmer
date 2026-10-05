require "test_helper"

class Sessions::UpdateEffortTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:needs_input)
    @session.update!(config: { "model" => "fable" })
  end

  test "sets a level the model takes and logs the change" do
    Sessions::UpdateEffort.call(session: @session, effort: "XHIGH", actor: :mcp)

    assert_equal "xhigh", @session.reload.config["effort"]
    assert_equal "fable", @session.config["model"]
    assert_equal "Effort updated via MCP (default → xhigh)", @session.logs.order(:created_at).last.content
  end

  test "default, blank and nil clear the override" do
    [ "default", "", nil ].each do |value|
      @session.update!(config: { "model" => "fable", "effort" => "max" })

      Sessions::UpdateEffort.call(session: @session, effort: value, actor: :api)

      assert_not @session.reload.config.key?("effort"), "#{value.inspect} should clear the effort"
    end
    assert_equal "Effort updated via API (max → default)", @session.logs.order(:created_at).last.content
  end

  test "the level the session already has is a no-op" do
    @session.update!(config: { "model" => "fable", "effort" => "high" })

    assert_no_difference -> { @session.logs.count } do
      Sessions::UpdateEffort.call(session: @session, effort: "high", actor: :web)
    end
  end

  test "refuses a level the model does not take, and writes nothing" do
    error = assert_raises(Sessions::UpdateEffort::Error) do
      Sessions::UpdateEffort.call(session: @session, effort: "turbo", actor: :web)
    end

    assert_match(/"turbo" is not valid for model "fable"/, error.message)
    assert_not @session.reload.config.key?("effort")
  end

  test "refuses any level on haiku" do
    @session.update!(config: { "model" => "haiku" })

    error = assert_raises(Sessions::UpdateEffort::Error) do
      Sessions::UpdateEffort.call(session: @session, effort: "low", actor: :web)
    end
    assert_match(/does not support an effort setting/, error.message)
  end

  test "refuses a non-string value" do
    assert_raises(Sessions::UpdateEffort::Error) do
      Sessions::UpdateEffort.call(session: @session, effort: [ "high" ], actor: :web)
    end
  end
end
