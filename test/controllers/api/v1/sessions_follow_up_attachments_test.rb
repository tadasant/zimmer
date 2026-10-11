# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# A follow-up's inline attachments: stored in the session's own storage and
# handed to the turn as images and files, whichever way the message goes.
class Api::V1::SessionsFollowUpAttachmentsTest < ActionDispatch::IntegrationTest
  include AttachmentFixtures

  setup do
    @headers = { "X-API-Key" => "test_api_key_attachments" }
    ENV["API_KEYS"] = "test_api_key_attachments"
  end

  teardown do
    ENV.delete("API_KEYS")
    cleanup_stored_attachments!
  end

  def attachments
    [
      { filename: "screen.png", media_type: "image/png", data: Base64.strict_encode64(minimal_png) },
      { filename: "deploy.log", media_type: "text/plain", data: Base64.strict_encode64("deploy failed at step 3\n") }
    ]
  end

  def reap(session)
    remember_storage(ImageStorageService.new(session_id: session.id))
    remember_storage(FileStorageService.new(session_id: session.id))
  end

  test "a delivered follow-up hands the turn its image and its file" do
    session = sessions(:needs_input)
    reap(session)
    AgentSessionJob.expects(:enqueue_with_prompt).with do |id, prompt, images:, files:|
      id == session.id && prompt == "What broke?" &&
        images.sole[:media_type] == "image/png" && File.exist?(images.sole[:path]) &&
        files.sole[:original_filename] == "deploy.log" && File.read(files.sole[:path]) == "deploy failed at step 3\n"
    end.returns(OpenStruct.new(job_id: "job-1"))

    post "/api/v1/sessions/#{session.id}/follow_up", params: { prompt: "What broke?", attachments: attachments }, headers: @headers, as: :json

    assert_response :success, response.body
  end

  test "a follow-up queued behind a turn keeps its attachments on the queued message" do
    session = sessions(:running)
    reap(session)
    Sessions::LiveTurn.stubs(:underway?).returns(true)

    post "/api/v1/sessions/#{session.id}/follow_up", params: { prompt: "And this?", attachments: attachments }, headers: @headers, as: :json

    assert_response :accepted, response.body
    queued = session.enqueued_messages.pending.last
    assert_equal "image/png", queued.images.sole["media_type"]
    assert_equal "deploy.log", queued.files.sole["original_filename"]
    assert File.exist?(queued.files.sole["path"])
  end

  test "a follow-up without attachments is unchanged" do
    session = sessions(:needs_input)
    AgentSessionJob.expects(:enqueue_with_prompt).with(session.id, "Plain", images: nil, files: nil).returns(OpenStruct.new(job_id: "job-2"))

    post "/api/v1/sessions/#{session.id}/follow_up", params: { prompt: "Plain" }, headers: @headers, as: :json

    assert_response :success
  end

  test "a bad attachment refuses the message rather than sending it without" do
    session = sessions(:needs_input)
    reap(session)
    AgentSessionJob.expects(:enqueue_with_prompt).never

    post "/api/v1/sessions/#{session.id}/follow_up",
      params: { prompt: "x", attachments: [ { filename: "a.png", media_type: "image/png", data: "not base64!" } ] }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_equal "Invalid attachment", JSON.parse(response.body)["error"]

    post "/api/v1/sessions/#{session.id}/follow_up",
      params: { prompt: "x", attachments: [ { filename: "", data: "eA==" } ] }, headers: @headers, as: :json
    assert_response :unprocessable_entity

    too_many = Array.new(Api::V1::SessionsController::FOLLOW_UP_ATTACHMENT_LIMIT + 1) { { filename: "f.txt", data: "eA==" } }
    post "/api/v1/sessions/#{session.id}/follow_up", params: { prompt: "x", attachments: too_many }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_match(/at most/, JSON.parse(response.body)["message"])
  end
end
