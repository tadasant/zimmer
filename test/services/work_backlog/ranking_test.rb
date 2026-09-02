# frozen_string_literal: true

require "test_helper"
require "support/work_backlog_helpers"

# The rules from WORK_BACKLOG.md, checked one at a time.
class WorkBacklog::RankingTest < ActiveSupport::TestCase
  include WorkBacklogHelpers

  Ranking = WorkBacklog::Ranking

  test "the bands are the spec's" do
    assert_equal [ 5000, 6000, 6999 ], Ranking.band_for("small").then { |b| [ b.floor, b.base, b.ceiling ] }
    assert_equal [ 2000, 3000, 3999 ], Ranking.band_for("medium").then { |b| [ b.floor, b.base, b.ceiling ] }
    assert_equal [ 500, 1000, 1999 ], Ranking.band_for("large").then { |b| [ b.floor, b.base, b.ceiling ] }
    assert_raises(ArgumentError) { Ranking.band_for("huge") }
  end

  test "an empty band starts at its base" do
    assert_equal 6000, Ranking.place("small").precedence
    assert_equal 3000, Ranking.place("medium").precedence
    assert_equal 1000, Ranking.place("large").precedence
  end

  test "an append lands GAP below the lowest unpinned peer of the same cost: FIFO within a band" do
    backlog_item(cost: "small", precedence: 6000)
    backlog_item(cost: "small", precedence: 5990)
    backlog_item(cost: "medium", precedence: 3000)

    assert_equal 5980, Ranking.place("small").precedence
    assert_equal 2990, Ranking.place("medium").precedence
  end

  test "a pinned item is not a peer, wherever it sits" do
    backlog_item(cost: "small", precedence: 6000)
    backlog_item(cost: "small", precedence: 4000, pinned: true) # buried below the floor by a human

    placement = Ranking.place("small")
    assert_equal 5990, placement.precedence, "the buried pin must not drag the next append past the floor"
  end

  test "an item outside its numeric band is not a peer; rerank is what brings it home" do
    drifted = backlog_item(cost: "small", precedence: 3000) # drifted (or hand-edited) small item

    placement = Ranking.place("small")
    assert_equal 6000, placement.precedence, "the drifted item does not drag the append out of the band"
    assert_not placement.respaced

    Ranking.rerank!
    assert_equal 6000, drifted.reload.precedence, "with the band otherwise empty it lands at the base"
  end

  test "an append clamps at the floor before it re-spaces" do
    backlog_item(cost: "small", precedence: 5015)

    placement = Ranking.place("small")
    assert_equal 5005, placement.precedence
    assert_not placement.respaced
  end

  test "a band at its floor is re-spaced before the append, order preserved" do
    # Three smalls right at the bottom, so the next slot would be the floor.
    a = backlog_item(cost: "small", precedence: 5020, added_at: 3.days.ago)
    b = backlog_item(cost: "small", precedence: 5010, added_at: 2.days.ago)
    c = backlog_item(cost: "small", precedence: 5000, added_at: 1.day.ago)

    placement = Ranking.place("small")

    assert placement.respaced
    # step = max(1, (6000 - 5000) / (3 + 2)) = 200: a → 6000, b → 5800, c → 5600, new → 5590
    assert_equal 6000, a.reload.precedence
    assert_equal 5800, b.reload.precedence
    assert_equal 5600, c.reload.precedence
    assert_equal 5590, placement.precedence
    assert_equal [ a.id, b.id, c.id ], WorkBacklogItem.queued.in_rank_order.pluck(:id)
  end

  test "a genuinely full band raises rather than crossing into the band below" do
    band = Ranking.band_for("large")
    # 600 large items crowding the floor. (base − floor) is 500, so the re-space
    # step is 1 and the lowest peer would land below the floor: no room.
    WorkBacklogItem.insert_all(
      600.times.map do |i|
        { key: "zimmer#full#{i}", issue_url: "https://github.com/tadasant/zimmer/issues/#{i}", repo: "tadasant/zimmer",
          surface: "zimmer", title: "t", kind: "bug", scope_direction: "convergent", estimated_cost: "large",
          added_at: Time.current, added_by: "issue-work-gate", added_via: "import", precedence: band.floor + i,
          pinned: false, status: "queued", payload: {}, created_at: Time.current, updated_at: Time.current }
      end
    )
    before = WorkBacklogItem.queued.order(:id).pluck(:precedence)

    error = assert_raises(Ranking::BandFull) { Ranking.place("large") }

    assert_match(/large band/, error.message)
    assert_equal before, WorkBacklogItem.queued.order(:id).pluck(:precedence), "nothing moved, nothing crossed the floor"
  end

  test "the band holds roughly five hundred appends before it is full, as the spec says" do
    # 490 smalls spread over the whole band, then the floor is reached and a
    # re-space still leaves room.
    WorkBacklogItem.insert_all(
      490.times.map do |i|
        { key: "zimmer#s#{i}", issue_url: "https://github.com/tadasant/zimmer/issues/#{i}", repo: "tadasant/zimmer",
          surface: "zimmer", title: "t", kind: "bug", scope_direction: "convergent", estimated_cost: "small",
          added_at: Time.current, added_by: "issue-work-gate", added_via: "import", precedence: 5000 + i,
          pinned: false, status: "queued", payload: {}, created_at: Time.current, updated_at: Time.current }
      end
    )

    placement = Ranking.place("small")

    assert placement.respaced
    assert_operator placement.precedence, :>, 5000
    assert_equal 0, WorkBacklogItem.queued.where(precedence: ...5000).count
  end

  test "rerank moves drifted unpinned items back into their band, oldest first, and leaves pinned ones alone" do
    backlog_item(cost: "small", precedence: 6000)
    drifted_new = backlog_item(cost: "small", precedence: 3500, added_at: 1.day.ago)
    drifted_old = backlog_item(cost: "small", precedence: 900, added_at: 5.days.ago)
    pinned = backlog_item(cost: "small", precedence: 42, pinned: true)
    fine_medium = backlog_item(cost: "medium", precedence: 3000)

    moved = Ranking.rerank!

    assert_equal 2, moved
    assert_equal 5990, drifted_old.reload.precedence, "the older drifted item is placed first"
    assert_equal 5980, drifted_new.reload.precedence
    assert_equal 42, pinned.reload.precedence
    assert_equal 3000, fine_medium.reload.precedence
    assert_equal 0, Ranking.rerank!, "a second pass finds nothing to move"
  end

  test "rerank ignores items that are no longer queued" do
    started = backlog_item(cost: "small", precedence: 1)
    started.mark_started!(session: sessions(:running), by: nil)

    assert_equal 0, Ranking.rerank!
    assert_equal 1, started.reload.precedence
  end

  test "with_lock is re-entrant" do
    value = Ranking.with_lock { Ranking.with_lock { 1 } }
    assert_equal 1, value
  end
end
