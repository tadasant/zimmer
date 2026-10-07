require "test_helper"

# The web model editor (PATCH /sessions/:id/update_model). The rules live in
# Sessions::UpdateModel; this covers what the door renders.
class SessionsControllerUpdateModelTest < ActionDispatch::IntegrationTest
  test "update_model persists the model and logs the change" do
    session = sessions(:needs_input)
    session.update!(config: { "model" => "opus" })

    assert_difference "session.logs.count", 1 do
      patch update_model_session_url(session), params: { model: "sonnet" }, as: :json
    end

    assert_response :success
    assert_equal({ "success" => true, "model" => "sonnet" }, JSON.parse(response.body))
    assert_equal "sonnet", session.reload.config["model"]
    assert_equal "Model updated (opus → sonnet)", session.logs.order(:created_at).last.content
  end

  test "update_model refuses a blank model" do
    session = sessions(:needs_input)

    patch update_model_session_url(session), params: { model: "" }, as: :json

    assert_response :unprocessable_entity
    assert_equal "model must be a non-empty string", JSON.parse(response.body)["error"]
  end

  test "update_model refuses a model the session's runtime does not offer" do
    session = sessions(:needs_input)
    session.update!(config: { "model" => "opus" })

    patch update_model_session_url(session), params: { model: "gpt-5" }, as: :json

    assert_response :unprocessable_entity
    assert_match(/not valid for runtime claude_code/, JSON.parse(response.body)["error"])
    assert_equal "opus", session.reload.config["model"]
  end

  test "update_model refuses a model that cannot keep the session's effort" do
    session = sessions(:needs_input)
    session.update!(config: { "model" => "fable", "effort" => "max" })

    patch update_model_session_url(session), params: { model: "haiku" }, as: :json

    assert_response :unprocessable_entity
    assert_match(/"haiku" does not support an effort setting/, JSON.parse(response.body)["error"])
    assert_equal "fable", session.reload.config["model"]
  end
end
