# frozen_string_literal: true

require "test_helper"

# Where a session card sits inside its dashboard section, and what a reorder does
# to the cards it did not name.
class SessionCardOrderTest < ActiveSupport::TestCase
  def setup
    Session.delete_all
    Category.delete_all
  end

  def build_session(created_at:, **attrs)
    Session.create!({
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      created_at: created_at
    }.merge(attrs))
  end

  def bucket(category_id = nil)
    Session.where(category_id: category_id).card_ordered.pluck(:id)
  end

  def values(ids)
    Session.where(id: ids).pluck(:id, :sort_order).to_h.values_at(*ids)
  end

  # `n` sessions in one bucket, oldest first. Each arrives on top, so the bucket reads
  # newest-first: the returned ids reversed.
  def build_bucket(n, category_id: nil)
    n.times.map { |i| build_session(created_at: (100 - i).hours.ago, category_id: category_id).id }
  end

  # A row nothing has ever placed holds the column default.
  def as_untouched!(ids)
    Session.where(id: ids).update_all(sort_order: 0)
  end

  # --- the read side ----------------------------------------------------------

  test "an untouched bucket, every card tied at 0, is newest-first" do
    ids = build_bucket(3)
    as_untouched!(ids)

    assert_equal ids.reverse, bucket
  end

  test "a new session arrives on top without rewriting anyone else" do
    ids = build_bucket(3)
    before = values(ids)

    fresh = build_session(created_at: 1.minute.ago)

    assert_equal [ fresh.id ] + ids.reverse, bucket
    assert_equal before, values(ids)
    assert_operator fresh.sort_order, :<, before.min
  end

  test "a new session arrives on top of a bucket that has been reordered" do
    a, b, c = build_bucket(3).reverse
    Session.reorder_cards!([ c, a, b ], category_id: nil)

    fresh = build_session(created_at: 1.minute.ago)

    assert_equal [ fresh.id, c, a, b ], bucket
  end

  # --- a drag: one card, next to its neighbour --------------------------------

  test "a drag places the moved card above the card below it" do
    a, b, c = build_bucket(3).reverse # a is on top

    # c dragged between a and b.
    Session.reorder_cards!([ a, c, b ], category_id: nil, moved_session_id: c)

    assert_equal [ a, c, b ], bucket
  end

  test "a drag to the bottom places the card below the card above it" do
    a, b, c = build_bucket(3).reverse

    Session.reorder_cards!([ b, c, a ], category_id: nil, moved_session_id: a)

    assert_equal [ b, c, a ], bucket
  end

  test "a drag rewrites only the cards whose rank changed" do
    ids = build_bucket(10).reverse # top first
    before = values(ids)

    # Card at rank 3 dragged to rank 1.
    moved = ids[3]
    Session.reorder_cards!([ ids[0], moved, ids[1], ids[2], ids[4] ], category_id: nil, moved_session_id: moved)

    after = values(ids)
    changed = ids.each_index.reject { |i| before[i] == after[i] }
    assert_equal [ 1, 2, 3 ], changed, "only ranks 1..3 moved, so only they are rewritten"
    assert_equal [ ids[0], moved, ids[1], ids[2] ] + ids[4..], bucket
  end

  # The review's measured case: an arrival at a fixed 0 collided with a renumbered
  # bucket's head and forced the next drag to rewrite the whole bucket.
  test "a drag after a new session arrives still rewrites only what moved" do
    ids = build_bucket(10).reverse
    Session.reorder_cards!(ids, category_id: nil) # settled, distinct values
    fresh = build_session(created_at: 1.minute.ago)
    everyone = [ fresh.id ] + ids
    before = values(everyone)

    Session.reorder_cards!([ fresh.id, ids[1], ids[0] ], category_id: nil, moved_session_id: ids[1])

    after = values(everyone)
    changed = everyone.each_index.reject { |i| before[i] == after[i] }
    assert_equal 2, changed.size, "a swap of two adjacent cards writes two rows"
  end

  test "the first reorder of an untouched bucket renumbers it, and the next one does not" do
    ids = build_bucket(6)
    as_untouched!(ids)
    top_first = bucket

    Session.reorder_cards!([ top_first[1], top_first[0] ], category_id: nil, moved_session_id: top_first[1])

    assert_equal (0...6).to_a, values(bucket), "ties at 0 have no order-preserving reuse"
    before = values(ids)

    now = bucket
    Session.reorder_cards!([ now[1], now[0] ], category_id: nil, moved_session_id: now[1])

    changed = ids.each_index.reject { |i| before[i] == values(ids)[i] }
    assert_equal 2, changed.size
  end

  # --- pagination: a page's ids are never read as positions -------------------

  test "a drag on the second page leaves the first page untouched" do
    top_first = build_bucket(6).reverse
    page_one = top_first[0, 3]
    page_two = top_first[3, 3]

    # The last card of page 2 dragged to its top.
    Session.reorder_cards!([ page_two[2], page_two[0], page_two[1] ], category_id: nil, moved_session_id: page_two[2])

    assert_equal page_one + [ page_two[2], page_two[0], page_two[1] ], bucket
  end

  test "a drag on the second page of an untouched bucket leaves the first page untouched" do
    ids = build_bucket(6)
    as_untouched!(ids)
    top_first = bucket
    page_two = top_first[3, 3]

    Session.reorder_cards!([ page_two[2], page_two[0], page_two[1] ], category_id: nil, moved_session_id: page_two[2])

    assert_equal top_first[0, 3] + [ page_two[2], page_two[0], page_two[1] ], bucket
  end

  # The review's second warning. A broadcast prepends a new session into the grid on
  # whatever page the reader is looking at, so page 2's DOM can hold a card whose slot
  # is the top of page 1. Dragging next to it must not pull anything onto page 1.
  test "a stray card on the page does not pull the dragged card onto another page" do
    # At three cards a page, the reader loaded page 2: t3, t4, t5.
    t = build_bucket(6).reverse
    # Then a new session arrived. Server-side it is on top of page 1; the broadcast
    # prepended it onto the grid the reader has open, so their page 2 now shows
    # stray, t3, t4, t5.
    stray = build_session(created_at: 1.minute.ago).id

    # They drag t5 to the top of the page's own cards: stray, t5, t3, t4.
    Session.reorder_cards!([ stray, t[5], t[3], t[4] ], category_id: nil, moved_session_id: t[5])

    assert_equal [ stray, t[0], t[1], t[2], t[5], t[3], t[4] ], bucket,
      "t5 lands above t3, on page 2 where it was dropped; page 1 is untouched"
  end

  # --- cross-section drags ----------------------------------------------------

  test "a cross-section drag persists both the category and the position" do
    inbox = Category.create!(name: "Inbox")
    a, b = build_bucket(2, category_id: inbox.id).reverse
    incoming = build_session(created_at: 1.minute.ago).id

    # Dropped between a and b.
    Session.reorder_cards!([ a, incoming, b ], category_id: inbox.id, moved_session_id: incoming)

    assert_equal inbox.id, Session.find(incoming).category_id
    assert_equal [ a, incoming, b ], bucket(inbox.id)
    assert_equal [], bucket(nil)
  end

  test "a card dragged in from another section does not bring that section's rank with it" do
    inbox = Category.create!(name: "Inbox")
    strays = build_bucket(5).reverse
    deepest = strays.last
    a, b = build_bucket(2, category_id: inbox.id).reverse

    Session.reorder_cards!([ a, deepest, b ], category_id: inbox.id, moved_session_id: deepest)

    assert_equal [ a, deepest, b ], bucket(inbox.id)
    assert_equal strays[0..3], bucket(nil), "the section it left keeps its own order"
  end

  test "a card dropped into an empty section is its only card" do
    inbox = Category.create!(name: "Inbox")
    card = build_session(created_at: 1.hour.ago).id

    Session.reorder_cards!([ card ], category_id: inbox.id, moved_session_id: card)

    assert_equal [ card ], bucket(inbox.id)
  end

  # --- favorited cards --------------------------------------------------------

  test "a favorited card keeps its place while it renders in the Starred group" do
    a, star, c = build_bucket(3).reverse
    Session.find(star).update!(favorited: true)

    # The section shows only a and c; c is dragged above a.
    Session.reorder_cards!([ c, a ], category_id: nil, moved_session_id: c)
    Session.find(star).update!(favorited: false)

    # `star` was below `a` and still is; only `c` moved.
    assert_equal [ c, a, star ], bucket
  end

  # --- rearranging several at once (REST / MCP, no moved card) ----------------

  test "without a moved card, the named cards are dealt into the slots they hold" do
    a, b, c = build_bucket(3).reverse

    Session.reorder_cards!([ c, b, a ], category_id: nil)

    assert_equal [ c, b, a ], bucket
  end

  test "without a moved card, a card between the named ones keeps its slot" do
    a, star, c = build_bucket(3).reverse
    Session.find(star).update!(favorited: true)

    Session.reorder_cards!([ c, a ], category_id: nil)

    assert_equal [ c, star, a ], bucket
  end

  test "a moved card that is not in the list falls back to dealing the list" do
    a, b, c = build_bucket(3).reverse

    Session.reorder_cards!([ b, a ], category_id: nil, moved_session_id: c)

    assert_equal [ b, a, c ], bucket
  end

  # --- category changes that do not go through reorder_cards! -----------------

  test "a card re-categorized without a position lands on top of its new bucket" do
    inbox = Category.create!(name: "Inbox")
    deep = build_bucket(4).first # the oldest, at the bottom of Uncategorized
    residents = build_bucket(3, category_id: inbox.id)
    before = values(residents)

    # The auto-categorizer and set_category both move a card this way.
    Session.find(deep).update!(category_id: inbox.id)

    assert_equal deep, bucket(inbox.id).first
    assert_equal before, values(residents), "nobody in the bucket was rewritten to make room"
  end

  test "a caller that names a position alongside the category keeps it" do
    inbox = Category.create!(name: "Inbox")
    card = build_session(created_at: 1.hour.ago)

    card.update!(category_id: inbox.id, sort_order: 7)

    assert_equal 7, card.reload.sort_order
  end

  test "a save that does not touch the category leaves the position alone" do
    a, b = build_bucket(2).reverse
    before = Session.find(b).sort_order

    Session.find(b).update!(title: "renamed")

    assert_equal before, Session.find(b).sort_order
    assert_equal [ a, b ], bucket
  end

  test "deleting a category puts its cards on top of Uncategorized, in their order" do
    uncategorized = build_bucket(3).reverse
    doomed = Category.create!(name: "Doomed")
    x, y = build_bucket(2, category_id: doomed.id).reverse
    Session.reorder_cards!([ y, x ], category_id: doomed.id, moved_session_id: y)

    doomed.destroy

    assert_equal [ y, x ] + uncategorized, bucket
  end

  test "deleting a category into an empty Uncategorized keeps the cards' order" do
    doomed = Category.create!(name: "Doomed")
    x, y = build_bucket(2, category_id: doomed.id).reverse
    Session.reorder_cards!([ y, x ], category_id: doomed.id, moved_session_id: y)

    doomed.destroy

    assert_equal [ y, x ], bucket
  end

  # --- the write only touches the bucket it was computed for -------------------

  test "a rank computed for one bucket is not written onto a card that has left it" do
    inbox = Category.create!(name: "Inbox")
    card = build_session(created_at: 1.hour.ago, category_id: inbox.id)
    before = card.reload.sort_order

    # What a reorder of Uncategorized would write if the card had been re-categorized
    # into Inbox between its read and its write.
    Session.send(:write_card_values, [ [ card.id, before + 99 ] ], category_id: nil)

    assert_equal before, card.reload.sort_order
  end

  # --- robustness -------------------------------------------------------------

  test "ids from another bucket are ignored" do
    inbox = Category.create!(name: "Inbox")
    a, b = build_bucket(2).reverse
    elsewhere = build_session(created_at: 3.hours.ago, category_id: inbox.id).id

    Session.reorder_cards!([ elsewhere, b, a ], category_id: nil)

    assert_equal [ b, a ], bucket
    assert_equal inbox.id, Session.find(elsewhere).category_id
  end

  test "unknown, blank and non-numeric ids are dropped" do
    a, b = build_bucket(2).reverse

    Session.reorder_cards!([ "", nil, "abc", 999_999, b.to_s, a ], category_id: nil)

    assert_equal [ b, a ], bucket
  end

  test "a duplicated id is honored once" do
    a, b = build_bucket(2).reverse

    Session.reorder_cards!([ b, a, b ], category_id: nil)

    assert_equal [ b, a ], bucket
  end

  test "an empty list is a no-op that still reports the bucket" do
    a, b = build_bucket(2).reverse

    assert_equal [ a, b ], Session.reorder_cards!([], category_id: nil)
    assert_equal [ a, b ], bucket
  end

  test "a reorder does not touch updated_at" do
    a, b = build_bucket(2).reverse
    before = Session.find(b).updated_at

    Session.reorder_cards!([ b, a ], category_id: nil, moved_session_id: b)

    assert_equal before.to_i, Session.find(b).updated_at.to_i
  end

  test "positions are written in batches when a renumber is larger than one batch" do
    original = SessionCardOrder::WRITE_BATCH_SIZE
    SessionCardOrder.send(:remove_const, :WRITE_BATCH_SIZE)
    SessionCardOrder.const_set(:WRITE_BATCH_SIZE, 2)

    ids = build_bucket(5)
    as_untouched!(ids)
    top_first = bucket
    Session.reorder_cards!(top_first.reverse, category_id: nil)

    assert_equal top_first.reverse, bucket
    assert_equal (0...5).to_a, values(bucket)
  ensure
    SessionCardOrder.send(:remove_const, :WRITE_BATCH_SIZE)
    SessionCardOrder.const_set(:WRITE_BATCH_SIZE, original)
  end
end
