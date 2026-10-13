# frozen_string_literal: true

require "test_helper"

# The dashboard's board filters on the REST surface, combined as the dashboard
# combines them: several statuses at once, with runtime, agent root, scheduling
# class, genesis and visibility — on the listing and on search alike.
class Api::V1::SessionsBoardFiltersTest < ActionDispatch::IntegrationTest
  setup do
    @headers = { "X-API-Key" => "test_api_key_board_filters" }
    ENV["API_KEYS"] = "test_api_key_board_filters"
    Session.delete_all
    @root = AgentRootsConfig.all.first
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  def make(title, status:, scheduling_class: "spot", root: nil)
    session = Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", title: title, status: status,
      scheduling_class: scheduling_class)
    session.update_columns(metadata: session.metadata.merge("agent_root_key" => root)) if root
    session
  end

  def titles(path, params)
    get path, params: params.merge(per_page: 100), headers: @headers
    assert_response :success, response.body
    JSON.parse(response.body)["sessions"].map { |s| s["title"] }.sort
  end

  test "several statuses combine, repeated or comma-separated" do
    make("asked", status: :needs_input)
    make("broke", status: :failed)
    make("busy", status: :running)

    assert_equal %w[asked broke], titles("/api/v1/sessions", status: %w[needs_input failed])
    assert_equal %w[asked broke], titles("/api/v1/sessions", status: "needs_input,failed")
    assert_equal %w[asked], titles("/api/v1/sessions", status: "needs_input")
  end

  test "naming archived includes archived sessions without show_archived" do
    make("asked", status: :needs_input)
    make("binned", status: :archived)

    assert_equal %w[asked binned], titles("/api/v1/sessions", status: %w[needs_input archived])
    assert_equal %w[asked], titles("/api/v1/sessions", {}), "archived is still left out by default"
  end

  test "statuses, scheduling class and agent root narrow together" do
    make("match", status: :needs_input, scheduling_class: "priority", root: @root.name)
    make("wrong class", status: :needs_input, scheduling_class: "spot", root: @root.name)
    make("wrong status", status: :running, scheduling_class: "priority", root: @root.name)
    make("wrong root", status: :needs_input, scheduling_class: "priority", root: "some-other-root")

    params = { status: %w[needs_input failed], priority_class: "priority", agent_root: @root.name }
    assert_equal [ "match" ], titles("/api/v1/sessions", params)
  end

  test "an agent root not in the catalog matches nothing rather than everything" do
    make("anything", status: :needs_input, root: @root.name)

    assert_equal [], titles("/api/v1/sessions", agent_root: "no-such-root")
  end

  test "search takes the same combined filters" do
    make("deploy staging", status: :needs_input, root: @root.name)
    make("deploy prod", status: :failed, root: @root.name)
    make("deploy other", status: :running, root: @root.name)

    assert_equal [ "deploy prod", "deploy staging" ], titles("/api/v1/sessions/search", q: "deploy", status: %w[needs_input failed], agent_root: @root.name)
  end

  test "an unknown status is refused with the valid ones named" do
    get "/api/v1/sessions", params: { status: %w[needs_input sleeping] }, headers: @headers

    assert_response :unprocessable_entity
    assert_match(/Unknown status sleeping/, JSON.parse(response.body)["message"])
  end

  test "configs lists every genesis the filter takes, with the dashboard's label" do
    get "/api/v1/configs", headers: @headers

    assert_response :success
    geneses = JSON.parse(response.body)["geneses"]
    assert_equal SessionGenesis::KEYS, geneses.map { |g| g["key"] }
    assert_equal SessionGenesis::KINDS.first.label, geneses.first["label"]
  end

  test "the Archived chip's query, status=archived with show_archived, lists the trash" do
    make("asked", status: :needs_input)
    make("binned", status: :archived)

    assert_equal %w[binned], titles("/api/v1/sessions", status: "archived", show_archived: "true")
  end

  test "combined filters apply to the User view too" do
    make("asked priority", status: :needs_input, scheduling_class: "priority", root: @root.name)
    make("asked spot", status: :needs_input, scheduling_class: "spot", root: @root.name)

    assert_equal [ "asked priority" ], titles("/api/v1/sessions", view: "user", status: "needs_input", priority_class: "priority")
  end

  test "search refuses an unknown status, and a status that is not a list, with a 422" do
    get "/api/v1/sessions/search", params: { q: "x", status: "sleeping" }, headers: @headers
    assert_response :unprocessable_entity

    get "/api/v1/sessions", params: { status: { a: "needs_input" } }, headers: @headers
    assert_response :unprocessable_entity
    assert_match(/a status or a list/, JSON.parse(response.body)["message"])
  end
end

