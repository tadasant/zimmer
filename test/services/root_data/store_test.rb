# frozen_string_literal: true

require "test_helper"

class RootData::StoreTest < ActiveSupport::TestCase
  include RootDataHelpers

  setup do
    @root = root_data_root("zimmer", data_collections: default_root_data_collections)
    @session = sessions(:running)
    @now = Time.zone.parse("2026-10-11 12:00:00")
    @store = store
  end

  def store(namespace: "zimmer", root: @root, now: @now)
    RootData::Store.new(namespace: namespace, root: root, writing_session: @session, now: now)
  end

  def counter(collection = "notes", namespace: "zimmer")
    AgentRootRecordCounter.find_by(namespace: namespace, collection: collection)
  end

  test "put inserts, then replaces in place, keeping the counter in step" do
    record, created = @store.put(collection: "notes", key: "pr-1", data: { "title" => "first" })
    assert created
    assert_equal @session.id, record.writing_session_id
    assert_equal @now + 30.days, record.expires_at, "expiry comes from retention_days at write time"
    assert_equal 1, counter.records_count

    replaced, created = @store.put(collection: "notes", key: "pr-1", data: { "title" => "a much longer second title" })
    assert_not created
    assert_equal record.id, replaced.id
    assert_equal({ "title" => "a much longer second title" }, replaced.reload.data)
    assert_equal 1, counter.records_count
    assert_equal replaced.data_bytes, counter.data_bytes
  end

  test "append adds keyless rows; a collection with no retention never expires" do
    a = @store.append(collection: "runs", data: { "n" => 1 })
    b = @store.append(collection: "runs", data: { "n" => 2 })

    assert_nil a.key
    assert_nil a.expires_at
    assert_not_equal a.id, b.id
    assert_equal 2, counter("runs").records_count
  end

  test "refuses a write to an undeclared collection and writes nothing" do
    error = assert_raises(RootData::Store::Refused) { @store.append(collection: "secrets", data: { "a" => 1 }) }
    assert_match(/not declared/, error.message)
    assert_match(/notes, runs/, error.message)
    assert_equal 0, AgentRootRecord.count
    assert_equal 0, AgentRootRecordCounter.count
  end

  test "validates data against the declared schema" do
    error = assert_raises(RootData::Store::Refused) { @store.put(collection: "notes", key: "k", data: { "status" => 1 }) }
    assert_match(/does not match the schema/, error.message)
    assert_equal 0, AgentRootRecord.count
  end

  test "refuses a broken declared schema rather than accepting unchecked" do
    root = root_data_root("zimmer", data_collections: { "notes" => { "schema" => { "type" => "bogus" } } })
    error = assert_raises(RootData::Store::Refused) { store(root: root).append(collection: "notes", data: { "a" => 1 }) }
    assert_match(/not a valid JSON Schema/, error.message)
  end

  test "refuses non-object data and oversize data" do
    assert_raises(RootData::Store::Refused) { @store.append(collection: "runs", data: [ 1, 2 ]) }

    big = { "blob" => "x" * RootData::Limits::MAX_DATA_BYTES }
    error = assert_raises(RootData::Store::Refused) { @store.append(collection: "runs", data: big) }
    assert_match(/limit is #{RootData::Limits::MAX_DATA_BYTES}/, error.message)
  end

  test "enforces the row cap from the counter" do
    @store.append(collection: "runs", data: { "n" => 1 })
    counter("runs").update!(records_count: RootData::Limits::MAX_RECORDS_PER_COLLECTION)

    error = assert_raises(RootData::Store::Refused) { store(now: @now + 2.minutes).append(collection: "runs", data: { "n" => 2 }) }
    assert_match(/the limit/, error.message)
    assert_equal 1, AgentRootRecord.count
  end

  test "a put that replaces an existing key is allowed at the row cap" do
    @store.put(collection: "notes", key: "k", data: { "title" => "a" })
    counter.update!(records_count: RootData::Limits::MAX_RECORDS_PER_COLLECTION)

    _, created = store(now: @now + 2.minutes).put(collection: "notes", key: "k", data: { "title" => "b" })
    assert_not created
  end

  test "rate-limits writes per collection per minute, and the window resets" do
    RootData::Limits.send(:remove_const, :MAX_WRITES_PER_MINUTE)
    RootData::Limits.const_set(:MAX_WRITES_PER_MINUTE, 2)

    @store.append(collection: "runs", data: { "n" => 1 })
    @store.append(collection: "runs", data: { "n" => 2 })
    error = assert_raises(RootData::Store::Refused) { @store.append(collection: "runs", data: { "n" => 3 }) }
    assert_match(/writes in the last minute/, error.message)

    # Another collection has its own window.
    @store.append(collection: "notes", data: { "title" => "t" })

    store(now: @now + 61.seconds).append(collection: "runs", data: { "n" => 4 })
    assert_equal 3, counter("runs").records_count
  ensure
    RootData::Limits.send(:remove_const, :MAX_WRITES_PER_MINUTE)
    RootData::Limits.const_set(:MAX_WRITES_PER_MINUTE, 60)
  end

  test "caps the number of collections per namespace" do
    RootData::Limits::MAX_COLLECTIONS_PER_NAMESPACE.times do |i|
      AgentRootRecordCounter.create!(namespace: "zimmer", collection: "c#{i}")
    end

    error = assert_raises(RootData::Store::Refused) { @store.append(collection: "runs", data: { "n" => 1 }) }
    assert_match(/collections, the limit/, error.message)
  end

  test "delete by key or id decrements the counter; a miss is nil" do
    @store.put(collection: "notes", key: "k", data: { "title" => "a" })
    other = @store.append(collection: "notes", data: { "title" => "b" })

    assert @store.delete(collection: "notes", key: "k")
    assert @store.delete(collection: "notes", id: other.id)
    assert_nil @store.delete(collection: "notes", key: "k")
    assert_equal 0, counter.records_count
    assert_equal 0, counter.data_bytes
  end

  test "namespaces are isolated: another namespace cannot read or delete by id" do
    mine = @store.append(collection: "notes", data: { "title" => "mine" })
    theirs = store(namespace: "other-root")

    assert_nil theirs.get(collection: "notes", id: mine.id)
    assert_nil theirs.delete(collection: "notes", id: mine.id)
    assert_empty theirs.search(collection: "notes")[:records]
    assert AgentRootRecord.exists?(mine.id)
  end

  test "search filters by jsonb containment and orders" do
    old = @store.append(collection: "notes", data: { "title" => "old", "status" => "open" })
    store(now: @now + 1.minute).append(collection: "notes", data: { "title" => "closed", "status" => "closed" })
    new = store(now: @now + 2.minutes).append(collection: "notes", data: { "title" => "new", "status" => "open" })

    result = @store.search(collection: "notes", filter: { "status" => "open" })
    assert_equal [ new.id, old.id ], result[:records].map(&:id)
    assert_not result[:has_more]

    oldest = @store.search(collection: "notes", order: "oldest", limit: 1)
    assert_equal [ old.id ], oldest[:records].map(&:id)
    assert oldest[:has_more]
    assert_equal 1, oldest[:next_offset]

    assert_raises(RootData::Store::Refused) { @store.search(collection: "notes", order: "sideways") }
    assert_raises(RootData::Store::Refused) { @store.search(collection: "notes", filter: "status=open") }
  end

  test "search stops at the response budget and says so" do
    payload = { "blob" => "x" * 30_000 }
    10.times { |i| store(now: @now + i.minutes).append(collection: "runs", data: payload) }

    result = @store.search(collection: "runs", limit: 10)
    assert result[:truncated]
    assert result[:has_more]
    assert_operator result[:records].size, :<, 10
    assert_equal result[:records].size, result[:next_offset]
  end

  test "reads do not consult the declarations, so an undeclared collection stays readable" do
    @store.append(collection: "runs", data: { "n" => 1 })
    undeclared = store(root: root_data_root("zimmer", data_collections: {}))

    assert_equal 1, undeclared.search(collection: "runs")[:records].size
    assert_equal [ "runs" ], undeclared.collections.map { |c| c[:name] }
    assert_nil undeclared.collections.first[:declaration]
  end
end
