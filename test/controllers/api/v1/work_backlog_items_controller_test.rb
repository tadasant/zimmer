# frozen_string_literal: true

require "test_helper"
require "support/work_backlog_helpers"

class Api::V1::WorkBacklogItemsControllerTest < ActionDispatch::IntegrationTest
  include WorkBacklogHelpers

  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key
  end

  teardown { ENV.delete("API_KEYS") }

  def body = JSON.parse(response.body)

  test "requires an API key" do
    get api_v1_work_backlog_items_path
    assert_response :unauthorized
  end

  test "index is the queue in rank order with positions, counts and the bands" do
    a = backlog_item(key: "zimmer#1", cost: "small", precedence: 6000)
    b = backlog_item(key: "zimmer#2", cost: "medium", precedence: 3000)
    c = backlog_item(key: "zimmer#3", cost: "small", precedence: 5990)
    started = backlog_item(key: "zimmer#4")
    started.mark_started!(session: sessions(:running), by: nil)

    get api_v1_work_backlog_items_path, headers: @headers

    assert_response :success
    items = body["work_backlog_items"]
    assert_equal [ a.key, c.key, b.key ], items.map { |i| i["key"] }
    assert_equal [ 1, 2, 3 ], items.map { |i| i["position"] }
    assert_equal 3, body["pagination"]["total_count"]
    assert_equal({ "queued" => 3, "started" => 1, "removed" => 0, "in_flight" => 1, "pinned" => 0 }, body["counts"])
    assert_equal 3, body.dig("ranking", "bands").size
  end

  test "index filters, and a filtered page keeps whole-queue positions" do
    backlog_item(key: "zimmer#1", cost: "small", precedence: 6000, surface: "zimmer")
    backlog_item(key: "strad#2", cost: "small", precedence: 5990, surface: "strad", repo: "tadasant/strad")

    get api_v1_work_backlog_items_path, params: { surface: "strad" }, headers: @headers

    assert_equal [ "strad#2" ], body["work_backlog_items"].map { |i| i["key"] }
    assert_equal [ 2 ], body["work_backlog_items"].map { |i| i["position"] }
  end

  test "index shows history with status all, and rejects a filter outside the vocabulary" do
    removed = backlog_item(key: "zimmer#1")
    removed.remove!(reason: "dup", by: "human")

    get api_v1_work_backlog_items_path, headers: @headers
    assert_equal 0, body["pagination"]["total_count"]

    get api_v1_work_backlog_items_path, params: { status: "all" }, headers: @headers
    assert_equal 1, body["pagination"]["total_count"]

    get api_v1_work_backlog_items_path, params: { estimated_cost: "huge" }, headers: @headers
    assert_response :unprocessable_entity
    assert_equal "Invalid filter", body["error"]
  end

  test "show finds by id or by key, preferring the queued row" do
    old = backlog_item(key: "zimmer#1")
    old.remove!(reason: "dup", by: "human")
    current = backlog_item(key: "zimmer#1")

    get api_v1_work_backlog_item_path(current.id), headers: @headers
    assert_equal current.id, body.dig("work_backlog_item", "id")

    get api_v1_work_backlog_item_path("zimmer#1"), headers: @headers
    assert_equal current.id, body.dig("work_backlog_item", "id")
    assert_equal 1, body.dig("work_backlog_item", "position")

    get api_v1_work_backlog_item_path("zimmer#999"), headers: @headers
    assert_response :not_found
  end

  test "create appends by the same rules the MCP tool uses, self-declared writer, human by default" do
    backlog_item(cost: "small", precedence: 6000)

    post api_v1_work_backlog_items_path,
      params: append_attributes(key: "zimmer#9", "notes" => "n", "acting_session_id" => sessions(:running).id),
      headers: @headers, as: :json

    assert_response :created
    item = body["work_backlog_item"]
    assert_equal true, body["created"]
    assert_equal 5990, item["precedence"]
    assert_equal 2, body["position"]
    assert_equal "human", item["added_by"]
    assert_equal "api", item["added_via"]
    assert_equal sessions(:running).id, item["writing_session_id"]
    assert_equal "n", item["notes"]
  end

  test "create keeps an unknown key in payload and accepts writing_session_id like the gate ledger does" do
    post api_v1_work_backlog_items_path,
      params: append_attributes(key: "zimmer#9", "new_gate_field" => { "x" => 1 }, "writing_session_id" => sessions(:running).id),
      headers: @headers, as: :json

    assert_response :created
    assert_equal({ "x" => 1 }, body.dig("work_backlog_item", "payload", "new_gate_field"))
    assert_equal sessions(:running).id, body.dig("work_backlog_item", "writing_session_id")
    assert_not body.dig("work_backlog_item", "payload").key?("work_backlog_item"), "the ParamsWrapper copy is not payload"
    assert_not body.dig("work_backlog_item", "payload").key?("writing_session_id")
  end

  test "create rejects a pinned flag it cannot read and a precedence outside the integer range" do
    post api_v1_work_backlog_items_path, params: append_attributes("pinned" => "maybe", "precedence" => 1), headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert body["messages"].any? { |m| m.include?("pinned must be true or false") }

    post api_v1_work_backlog_items_path, params: append_attributes(key: "zimmer#yes", "pinned" => "yes", "precedence" => 7000), headers: @headers, as: :json
    assert_response :created
    assert_equal true, body.dig("work_backlog_item", "pinned")
    WorkBacklogItem.delete_all

    post api_v1_work_backlog_items_path, params: append_attributes("pinned" => true, "precedence" => 2**31), headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert body["messages"].any? { |m| m.include?("Precedence") }
    assert_equal 0, WorkBacklogItem.count
  end

  test "create is idempotent on key, answering 200 and created false" do
    post api_v1_work_backlog_items_path, params: append_attributes(key: "zimmer#9"), headers: @headers, as: :json
    post api_v1_work_backlog_items_path, params: append_attributes(key: "zimmer#9"), headers: @headers, as: :json

    assert_response :ok
    assert_equal false, body["created"]
    assert_equal 1, WorkBacklogItem.count
  end

  test "create lets a human hand-place and pin, and add an issueless item with a prompt" do
    post api_v1_work_backlog_items_path,
      params: append_attributes(key: "manual-x", "issue_url" => nil, "prompt" => "Verbatim.", "pinned" => true, "precedence" => 8000),
      headers: @headers, as: :json

    assert_response :created
    assert_equal true, body.dig("work_backlog_item", "pinned")
    assert_equal 8000, body.dig("work_backlog_item", "precedence")
    assert_equal "Verbatim.", body.dig("work_backlog_item", "prompt")
  end

  test "create rejects a malformed item with 422 and every reason" do
    post api_v1_work_backlog_items_path, params: append_attributes("estimated_cost" => "huge"), headers: @headers, as: :json

    assert_response :unprocessable_entity
    assert_equal "Invalid work backlog item", body["error"]
    assert body["messages"].any? { |m| m.include?("Estimated cost") }
    assert_equal 0, WorkBacklogItem.count
  end

  test "pull starts the top N as spot sessions and removes dead ones" do
    backlog_item(key: "zimmer#1", precedence: 6000)
    backlog_item(key: "zimmer#2", precedence: 5990)
    groomer = sessions(:running)

    assert_difference("Session.count", 1) do
      post pull_api_v1_work_backlog_items_path,
        params: { count: 1, dead: [ { key: "zimmer#2", reason: "issue_closed" } ], acting_session_id: groomer.id },
        headers: @headers, as: :json
    end

    assert_response :success
    assert_equal [ "zimmer#1" ], body["started"].map { |s| s.dig("work_backlog_item", "key") }
    session = body["started"].first["session"]
    assert_equal "spot", session["scheduling_class"]
    assert_equal groomer.id, session["parent_session_id"]
    assert_match %r{/sessions/#{session['id']}\z}, session["url"]
    assert_equal [ "zimmer#2" ], body["removed"].map { |r| r.dig("work_backlog_item", "key") }
    assert_equal "session:#{groomer.id}", WorkBacklogItem.find_by(key: "zimmer#2").removed_by
    assert_equal 0, body.dig("counts", "queued")
  end

  test "pull by keys starts exactly those, and a single dead object is accepted as a list of one" do
    backlog_item(key: "zimmer#1", precedence: 6000)
    backlog_item(key: "zimmer#2", precedence: 5990)
    backlog_item(key: "zimmer#3", precedence: 5980)

    post pull_api_v1_work_backlog_items_path,
      params: { keys: [ "zimmer#3" ], dead: { key: "zimmer#2", reason: "issue_has_open_pr" } },
      headers: @headers, as: :json

    assert_response :success
    assert_equal [ "zimmer#3" ], body["started"].map { |s| s.dig("work_backlog_item", "key") }
    assert_equal [ "zimmer#2" ], body["removed"].map { |r| r.dig("work_backlog_item", "key") }
    assert_equal "api", WorkBacklogItem.find_by(key: "zimmer#2").removed_by
    assert WorkBacklogItem.find_by(key: "zimmer#1").queued?
  end

  test "start_now with an acting session makes the priority session its child" do
    backlog_item(key: "zimmer#1")
    parent = sessions(:running)

    post start_now_api_v1_work_backlog_item_path("zimmer#1"), params: { acting_session_id: parent.id }, headers: @headers, as: :json

    assert_response :created
    assert_equal parent.id, body.dig("session", "parent_session_id")
    assert_equal "priority", body.dig("session", "scheduling_class")
    assert_equal parent.id, body.dig("work_backlog_item", "started_by_session_id")
  end

  test "a key with a dot in it routes" do
    backlog_item(key: "next.js#5", repo: "vercel/next.js", issue_url: "https://github.com/vercel/next.js/issues/5")

    get api_v1_work_backlog_item_path("next.js#5"), headers: @headers

    assert_response :success
    assert_equal "next.js#5", body.dig("work_backlog_item", "key")
  end

  test "pull rejects a discretionary removal reason" do
    backlog_item(key: "zimmer#1")

    post pull_api_v1_work_backlog_items_path,
      params: { dead: [ { key: "zimmer#1", reason: "meh" } ] }, headers: @headers, as: :json

    assert_response :unprocessable_entity
    assert_equal "Invalid pull", body["error"]
  end

  test "start_now spawns a priority session for a queued item and marks it started" do
    item = backlog_item(key: "zimmer#1")

    assert_difference("Session.count", 1) do
      post start_now_api_v1_work_backlog_item_path("zimmer#1"), headers: @headers, as: :json
    end

    assert_response :created
    assert_equal "priority", body.dig("session", "scheduling_class")
    assert_equal "started", body.dig("work_backlog_item", "status")
    assert_equal body.dig("session", "id"), item.reload.started_session_id

    post start_now_api_v1_work_backlog_item_path("zimmer#1"), headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_equal "Not queued", body["error"]
  end

  test "pin places the item exactly and keeps it there; unpin returns it to its band" do
    item = backlog_item(key: "zimmer#1", cost: "medium", precedence: 3000)
    backlog_item(key: "zimmer#2", cost: "small", precedence: 6000)

    patch pin_api_v1_work_backlog_item_path(item.id), params: { precedence: 9000 }, headers: @headers, as: :json

    assert_response :success
    assert_equal true, body.dig("work_backlog_item", "pinned")
    assert_equal 9000, body.dig("work_backlog_item", "precedence")
    assert_equal 1, body.dig("work_backlog_item", "position")

    patch unpin_api_v1_work_backlog_item_path(item.id), headers: @headers, as: :json

    assert_response :success
    assert_equal false, body.dig("work_backlog_item", "pinned")
    assert_equal 3000, body.dig("work_backlog_item", "precedence"), "re-ranked back into the medium band"
    assert_equal 2, body.dig("work_backlog_item", "position")
  end

  test "pin needs a precedence and a queued item" do
    item = backlog_item(key: "zimmer#1")

    patch pin_api_v1_work_backlog_item_path(item.id), headers: @headers, as: :json
    assert_response :unprocessable_entity

    patch pin_api_v1_work_backlog_item_path(item.id), params: { precedence: "top" }, headers: @headers, as: :json
    assert_response :unprocessable_entity

    patch pin_api_v1_work_backlog_item_path(item.id), params: { precedence: 2**31 }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_not item.reload.pinned

    item.remove!(reason: "dup", by: "human")
    patch pin_api_v1_work_backlog_item_path(item.id), params: { precedence: 1 }, headers: @headers, as: :json
    assert_response :unprocessable_entity
  end

  test "remove takes the item off the queue with a reason, keeping the row" do
    item = backlog_item(key: "zimmer#1")

    post remove_api_v1_work_backlog_item_path(item.id), headers: @headers, as: :json
    assert_response :unprocessable_entity

    post remove_api_v1_work_backlog_item_path(item.id), params: { reason: "superseded by the rewrite" }, headers: @headers, as: :json

    assert_response :success
    assert_equal "removed", body.dig("work_backlog_item", "status")
    assert_equal "human", body.dig("work_backlog_item", "removed_by")
    assert_equal "superseded by the rewrite", body.dig("work_backlog_item", "removal_reason")
    assert_equal 1, WorkBacklogItem.count
  end
end
