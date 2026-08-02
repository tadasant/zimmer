# frozen_string_literal: true

require "test_helper"

module Supervisor
  # The roster screen exists to make one thing possible without a deploy:
  # linking a Slack user ID to a human. These assertions are that path
  # end-to-end, since it is the reason the roster is a table.
  class UsersControllerTest < ActionDispatch::IntegrationTest
    include SupervisorAuthTestHelper
    include SupervisorAuthTestHelper::AutoBasicAuth

    setup do
      @tadas = users(:tadasant)
    end

    test "the index lists every named human" do
      get supervisor_users_url

      assert_response :success
      assert_select "h1", "Users"
      assert_match "tadasant", response.body
      assert_match "juliehazz", response.body
    end

    test "the show page names the human and their linkage" do
      get supervisor_user_url(@tadas)

      assert_response :success
      assert_match "tadas@tadasant.com", response.body
    end

    test "the form renders" do
      get edit_supervisor_user_url(@tadas)
      assert_response :success

      get new_supervisor_user_url
      assert_response :success
    end

    # The whole point of the screen.
    test "linking a Slack user ID takes effect without a deploy" do
      assert_nil User.for_slack_user_id("U01TADAS")

      patch supervisor_user_url(@tadas), params: {
        user: {
          key: @tadas.key,
          display_name: @tadas.display_name,
          email: @tadas.email,
          slack_user_ids_list: "U01TADAS, U01TADAS_ALT",
          notes: @tadas.notes
        }
      }

      assert_redirected_to supervisor_user_url(@tadas)
      assert_equal %w[U01TADAS U01TADAS_ALT], @tadas.reload.slack_user_ids
      assert_equal "tadasant", User.for_slack_user_id("U01TADAS").key
    end

    test "notes are editable, and reach the prompt block" do
      session = Session.create!(
        agent_runtime: "claude_code",
        prompt: "work",
        git_root: "https://github.com/test/repo.git",
        branch: "main"
      )
      session.human_messages.create!(
        author: "tadasant",
        channel: HumanMessage::WEB_UI,
        content: "ship it",
        occurred_at: Time.current
      )

      patch supervisor_user_url(@tadas), params: {
        user: {
          key: @tadas.key,
          display_name: @tadas.display_name,
          email: @tadas.email,
          slack_user_ids_list: "",
          notes: "Tadas is master"
        }
      }

      assert_equal "Tadas is master", @tadas.reload.notes
      assert_includes SessionHumanMessages.new(session).render_for_prompt, "Tadas is master"
    end

    test "a new human can be added" do
      assert_difference("User.count", 1) do
        post supervisor_users_url, params: {
          user: {
            key: "newhuman",
            display_name: "New Human",
            email: "new@tadasant.com",
            slack_user_ids_list: "U02NEW",
            notes: ""
          }
        }
      end

      assert_equal "newhuman", User.for_slack_user_id("U02NEW").key
    end

    test "the panel is closed without the supervisor credential" do
      get supervisor_users_url, headers: { "HTTP_AUTHORIZATION" => "" }

      assert_response :unauthorized
    end
  end
end
