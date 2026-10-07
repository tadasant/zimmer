require "test_helper"

class Sessions::UpdateModelTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:needs_input)
    @session.update!(config: { "model" => "opus", "other_key" => "preserved" })
  end

  test "sets a model the runtime offers, keeps other config, and logs the change" do
    Sessions::UpdateModel.call(session: @session, model: "  sonnet  ", actor: :mcp)

    assert_equal "sonnet", @session.reload.config["model"]
    assert_equal "preserved", @session.config["other_key"]
    assert_equal "Model updated via MCP (opus → sonnet)", @session.logs.order(:created_at).last.content
  end

  test "labels the log row by actor" do
    Sessions::UpdateModel.call(session: @session, model: "fable", actor: :web)
    assert_equal "Model updated (opus → fable)", @session.logs.order(:created_at).last.content

    Sessions::UpdateModel.call(session: @session, model: "haiku", actor: :api)
    assert_equal "Model updated via API (fable → haiku)", @session.logs.order(:created_at).last.content
  end

  test "the model the session already has is a no-op" do
    assert_no_difference -> { @session.logs.count } do
      Sessions::UpdateModel.call(session: @session, model: "opus", actor: :web)
    end
  end

  test "a retry after a failed write still writes the model" do
    # A failed UPDATE leaves the new model on the in-memory record; the retry
    # must compare against what is stored, not short-circuit as a no-op.
    @session.config = @session.config.merge("model" => "sonnet")

    Sessions::UpdateModel.call(session: @session, model: "sonnet", actor: :web)

    assert_equal "sonnet", @session.reload.config["model"]
    assert_equal "Model updated (opus → sonnet)", @session.logs.order(:created_at).last.content
  end

  test "refuses a missing, blank or non-String model and writes nothing" do
    [ nil, "", "   ", 42, [ "sonnet" ] ].each do |value|
      assert_raises(Sessions::UpdateModel::InvalidParameter, "#{value.inspect} should be refused") do
        Sessions::UpdateModel.call(session: @session, model: value, actor: :web)
      end
    end
    assert_equal "opus", @session.reload.config["model"]
  end

  test "refuses a model the runtime does not offer, naming the valid ones" do
    error = assert_raises(Sessions::UpdateModel::InvalidModel) do
      Sessions::UpdateModel.call(session: @session, model: "gpt-5", actor: :web)
    end

    assert_match(/"gpt-5" is not valid for runtime claude_code/, error.message)
    assert_match(/Valid models: .*sonnet/, error.message)
    assert_equal "opus", @session.reload.config["model"]
  end

  test "refuses a model that cannot keep the session's effort, and writes nothing" do
    @session.update!(config: { "model" => "fable", "effort" => "max" })

    assert_no_difference -> { @session.logs.count } do
      assert_raises(ActiveRecord::RecordInvalid) do
        Sessions::UpdateModel.call(session: @session, model: "haiku", actor: :web)
      end
    end
    assert_equal "fable", @session.reload.config["model"]
  end
end
