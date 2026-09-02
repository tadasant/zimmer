# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class WorkBacklog::ImporterTest < ActiveSupport::TestCase
  FIXTURE = Rails.root.join("test/fixtures/files/work_backlog_sample.json")

  def fixture_items = JSON.parse(File.read(FIXTURE))

  def import(path = FIXTURE)
    WorkBacklog::Importer.new(source: WorkBacklog::Source.resolve(path: path), logger: Rails.logger).call
  end

  test "imports every item, verbatim, in the file's order" do
    result = import

    assert_equal fixture_items.size, result.seen
    assert_equal fixture_items.size, result.imported
    assert_equal 0, result.already_present
    assert_equal 0, result.rejected

    assert_equal fixture_items.map { |i| i["id"] }, WorkBacklogItem.queued.in_rank_order.pluck(:key),
                 "the queue comes out in the order the file was stored in"
    assert_equal fixture_items.map { |i| i["precedence"] }, WorkBacklogItem.queued.in_rank_order.pluck(:precedence)

    item = WorkBacklogItem.find_by!(key: "zimmer#498")
    assert_equal "https://github.com/tadasant/zimmer/issues/498", item.issue_url
    assert_equal "tadasant/zimmer", item.repo
    assert_equal "small", item.estimated_cost
    assert_equal "queue-migration", item.added_by
    assert_equal WorkBacklogItem::IMPORT, item.added_via
    assert_equal Date.new(2026, 8, 19), item.decided_at
    assert_equal Time.utc(2026, 8, 29), item.added_at
    assert_equal 5, item.ratings.size
    assert_nil item.writing_session_id
    assert item.queued?
  end

  test "the pinned, issueless human item survives with its prompt and its placement" do
    import

    item = WorkBacklogItem.find_by!(key: "manual-refresh-the-docs")
    assert item.pinned
    assert_equal 7500, item.precedence
    assert_nil item.issue_url
    assert_equal "human", item.added_by
    assert_match(/Verbatim ask/, item.prompt)
  end

  test "payload holds everything that is not a column, and nothing that is" do
    import

    item = WorkBacklogItem.find_by!(key: "strad#7")
    assert_equal %w[gate_session notes prompt ratings].sort, item.payload.keys.sort
    assert_equal "fixture", item.notes
  end

  test "is idempotent: a second pass writes nothing" do
    import
    before = WorkBacklogItem.count

    result = import

    assert_equal before, WorkBacklogItem.count
    assert_equal 0, result.imported
    assert_equal fixture_items.size, result.already_present
  end

  test "a key already present in any status is not resurrected" do
    import
    started = WorkBacklogItem.find_by!(key: "zimmer#498")
    started.mark_started!(session: sessions(:running), by: nil)

    result = import

    assert_equal 0, result.imported
    assert_equal 1, WorkBacklogItem.where(key: "zimmer#498").count
    assert started.reload.started?
  end

  test "one bad item does not cost the rest, and is named" do
    items = fixture_items
    items << { "id" => "zimmer#bad", "issue" => "https://x", "repo" => "nope", "surface" => "zimmer", "title" => "t",
               "kind" => "bug", "scope_direction" => "convergent", "estimated_cost" => "huge", "precedence" => 1 }
    items << { "title" => "no id at all" }
    path = File.join(Dir.mktmpdir, "WORK_BACKLOG.json")
    File.write(path, JSON.generate(items))

    result = import(path)

    assert_equal fixture_items.size, result.imported
    assert_equal 2, result.rejected
    assert_match(/Estimated cost/, result.rejections.find { |r| r.key == "zimmer#bad" }.reason)
    assert_match(/no id/, result.rejections.find { |r| r.key == "(no id)" }.reason)
  end

  test "the mapping is the file's schema" do
    attrs = WorkBacklog::Importer.attributes_for(fixture_items.first)

    assert_equal "manual-refresh-the-docs", attrs[:key]
    assert_equal WorkBacklogItem::QUEUED, attrs[:status]
    assert_equal WorkBacklogItem::IMPORT, attrs[:added_via]
    assert_not attrs[:payload].key?("id")
    assert attrs[:payload].key?("prompt")
  end

  test "a missing or malformed file is Unavailable" do
    assert_raises(WorkBacklog::Source::Unavailable) { import("/nope/WORK_BACKLOG.json") }

    path = File.join(Dir.mktmpdir, "WORK_BACKLOG.json")
    File.write(path, "{not json")
    assert_raises(WorkBacklog::Source::Unavailable) { import(path) }

    File.write(path, JSON.generate({ "not" => "an array" }))
    assert_raises(WorkBacklog::Source::Unavailable) { import(path) }
  end
end
