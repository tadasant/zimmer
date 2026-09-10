# frozen_string_literal: true

require "test_helper"

# Where a session card sits inside its dashboard section, and what a reorder does
# to the cards it did not name.
class SessionCardOrderTest < ActiveSupport::TestCase
  def setup
    Session.delete_all
    Category.delete_all
  end

  # Sessions are created oldest-first, so `card_ordered` (created_at DESC on the
  # sort_order-0 tie) hands them back in reverse. Naming them explicitly keeps the
  # assertions readable.
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

  # --- the untouched default --------------------------------------------------

  test "a bucket nobody has reordered is newest-first, exactly as it was before sort_order existed" do
    old = build_session(created_at: 3.hours.ago)
    mid = build_session(created_at: 2.hours.ago)
    new = build_session(created_at: 1.hour.ago)

    assert_equal [ 0, 0, 0 ], [ old, mid, new ].map(&:sort_order)
    assert_equal [ new.id, mid.id, old.id ], bucket
  end

  # --- reordering within one section -----------------------------------------

  test "a reorder persists the order it was given" do
    a = build_session(created_at: 3.hours.ago)
    b = build_session(created_at: 2.hours.ago)
    c = build_session(created_at: 1.hour.ago)

    Session.reorder_cards!([ a.id, c.id, b.id ], category_id: nil)

    assert_equal [ a.id, c.id, b.id ], bucket
  end

  test "the order survives a fresh read of the relation" do
    a = build_session(created_at: 3.hours.ago)
    b = build_session(created_at: 2.hours.ago)

    Session.reorder_cards!([ a.id, b.id ], category_id: nil)

    # Nothing cached: re-derive the whole thing the way a page render does.
    assert_equal [ a.id, b.id ], Session.where(category_id: nil).card_ordered.pluck(:id)
  end

  test "a reorder is idempotent — re-sending the same order writes nothing" do
    a = build_session(created_at: 2.hours.ago)
    b = build_session(created_at: 1.hour.ago)
    Session.reorder_cards!([ a.id, b.id ], category_id: nil)

    before = Session.where(id: [ a.id, b.id ]).pluck(:id, :sort_order, :updated_at)
    Session.reorder_cards!([ a.id, b.id ], category_id: nil)

    assert_equal before, Session.where(id: [ a.id, b.id ]).pluck(:id, :sort_order, :updated_at)
  end

  test "a reorder does not touch updated_at" do
    a = build_session(created_at: 2.hours.ago)
    b = build_session(created_at: 1.hour.ago)
    before = a.reload.updated_at

    Session.reorder_cards!([ a.id, b.id ], category_id: nil)

    assert_equal before.to_i, a.reload.updated_at.to_i
  end

  # --- a new session still lands at the top -----------------------------------

  test "a session created after a reorder lands at the top of the bucket" do
    a = build_session(created_at: 3.hours.ago)
    b = build_session(created_at: 2.hours.ago)
    Session.reorder_cards!([ a.id, b.id ], category_id: nil)

    fresh = build_session(created_at: Time.current)

    # `fresh` arrives at sort_order 0 and ties with `a`; created_at DESC breaks it.
    assert_equal 0, fresh.sort_order
    assert_equal [ fresh.id, a.id, b.id ], bucket
  end

  # --- pagination: global positions, not page-local indices -------------------

  test "reordering the second page leaves the first page untouched" do
    sessions = 6.times.map { |i| build_session(created_at: (10 - i).hours.ago) }
    ordered = sessions.map(&:id)
    # Normalize the whole bucket first, the way a first drag on page 1 would.
    Session.reorder_cards!(ordered, category_id: nil)

    page_two = ordered[3, 3]
    Session.reorder_cards!(page_two.reverse, category_id: nil)

    assert_equal ordered[0, 3] + page_two.reverse, bucket
  end

  test "reordering the first page leaves the second page untouched" do
    sessions = 6.times.map { |i| build_session(created_at: (10 - i).hours.ago) }
    ordered = sessions.map(&:id)
    Session.reorder_cards!(ordered, category_id: nil)

    page_one = ordered[0, 3]
    Session.reorder_cards!(page_one.reverse, category_id: nil)

    assert_equal page_one.reverse + ordered[3, 3], bucket
  end

  test "a page-two reorder that predates any normalization still cannot renumber page one" do
    # No reorder has happened at all, so every card holds sort_order 0 and the
    # order is purely created_at. The page-2 block must splice in at slot 3.
    sessions = 6.times.map { |i| build_session(created_at: (10 - i).hours.ago) }
    ordered = Session.where(category_id: nil).card_ordered.pluck(:id)
    page_two = ordered[3, 3]

    Session.reorder_cards!(page_two.reverse, category_id: nil)

    assert_equal ordered[0, 3] + page_two.reverse, bucket
    assert_equal sessions.size, ordered.size
  end

  # --- cross-section moves ----------------------------------------------------

  test "a cross-section drag persists both the category and the position" do
    inbox = Category.create!(name: "Inbox")
    a = build_session(created_at: 3.hours.ago, category_id: inbox.id)
    b = build_session(created_at: 2.hours.ago, category_id: inbox.id)
    incoming = build_session(created_at: 1.hour.ago, category_id: nil)

    # Dropped between a and b.
    Session.reorder_cards!([ a.id, incoming.id, b.id ], category_id: inbox.id, moved_session_id: incoming.id)

    assert_equal inbox.id, incoming.reload.category_id
    assert_equal [ a.id, incoming.id, b.id ], bucket(inbox.id)
    assert_equal [], bucket(nil)
  end

  test "a card dragged in from another section does not drag that section's ranks with it" do
    inbox = Category.create!(name: "Inbox")
    # Give the incoming card a high rank in its own bucket first, so a naive
    # implementation would splice it into the destination at that rank.
    strays = 5.times.map { |i| build_session(created_at: (10 - i).hours.ago) }
    Session.reorder_cards!(strays.map(&:id), category_id: nil)
    incoming = strays.last

    a = build_session(created_at: 3.hours.ago, category_id: inbox.id)
    b = build_session(created_at: 2.hours.ago, category_id: inbox.id)

    Session.reorder_cards!([ incoming.id, a.id, b.id ], category_id: inbox.id, moved_session_id: incoming.id)

    assert_equal [ incoming.id, a.id, b.id ], bucket(inbox.id)
    assert_equal 0, incoming.reload.sort_order
  end

  test "the section a card left keeps its own order" do
    inbox = Category.create!(name: "Inbox")
    a = build_session(created_at: 4.hours.ago)
    b = build_session(created_at: 3.hours.ago)
    c = build_session(created_at: 2.hours.ago)
    Session.reorder_cards!([ a.id, b.id, c.id ], category_id: nil)

    Session.reorder_cards!([ b.id ], category_id: inbox.id, moved_session_id: b.id)

    assert_equal [ a.id, c.id ], bucket
    assert_equal [ b.id ], bucket(inbox.id)
  end

  # --- favorited cards --------------------------------------------------------

  test "a favorited card holds its slot while it renders in the Starred group" do
    a = build_session(created_at: 4.hours.ago)
    star = build_session(created_at: 3.hours.ago)
    c = build_session(created_at: 2.hours.ago)
    Session.reorder_cards!([ a.id, star.id, c.id ], category_id: nil)

    star.update!(favorited: true)
    # The section now shows only a and c; a drag there names only those two.
    Session.reorder_cards!([ a.id, c.id ], category_id: nil)
    star.update!(favorited: false)

    assert_equal [ a.id, star.id, c.id ], bucket
  end

  # --- category changes that do not go through reorder_cards! ----------------

  test "a card re-categorized without a position drops to the top-tie of its new bucket" do
    inbox = Category.create!(name: "Inbox")
    strays = 4.times.map { |i| build_session(created_at: (10 - i).hours.ago) }
    Session.reorder_cards!(strays.map(&:id), category_id: nil)
    deep = strays.last
    assert_equal 3, deep.reload.sort_order

    a = build_session(created_at: 3.hours.ago, category_id: inbox.id)
    b = build_session(created_at: 2.hours.ago, category_id: inbox.id)
    c = build_session(created_at: 1.hour.ago, category_id: inbox.id)
    Session.reorder_cards!([ a.id, b.id, c.id ], category_id: inbox.id)

    # The auto-categorizer and set_category both move a card this way.
    deep.update!(category_id: inbox.id)

    assert_equal 0, deep.reload.sort_order
    # Tied with `a` at 0 and older than it, so second — not at rank 3 of a bucket it
    # was never ranked in.
    assert_equal [ a.id, deep.id, b.id, c.id ], bucket(inbox.id)
  end

  test "a caller that names a position alongside the category keeps it" do
    inbox = Category.create!(name: "Inbox")
    card = build_session(created_at: 1.hour.ago)

    card.update!(category_id: inbox.id, sort_order: 7)

    assert_equal 7, card.reload.sort_order
  end

  test "a save that does not touch the category leaves the position alone" do
    a = build_session(created_at: 2.hours.ago)
    b = build_session(created_at: 1.hour.ago)
    Session.reorder_cards!([ b.id, a.id ], category_id: nil)

    a.update!(title: "renamed")

    assert_equal 1, a.reload.sort_order
  end

  test "deleting a category resets its orphaned cards before they land in Uncategorized" do
    doomed = Category.create!(name: "Doomed")
    x = build_session(created_at: 3.hours.ago, category_id: doomed.id)
    y = build_session(created_at: 2.hours.ago, category_id: doomed.id)
    Session.reorder_cards!([ x.id, y.id ], category_id: doomed.id)
    assert_equal [ 0, 1 ], [ x.reload.sort_order, y.reload.sort_order ]

    doomed.destroy

    assert_equal [ nil, nil ], [ x.reload.category_id, y.reload.category_id ]
    assert_equal [ 0, 0 ], [ x.sort_order, y.sort_order ]
  end

  # --- robustness -------------------------------------------------------------

  test "ids from another bucket are ignored" do
    inbox = Category.create!(name: "Inbox")
    a = build_session(created_at: 2.hours.ago)
    b = build_session(created_at: 1.hour.ago)
    elsewhere = build_session(created_at: 3.hours.ago, category_id: inbox.id)

    Session.reorder_cards!([ elsewhere.id, a.id, b.id ], category_id: nil)

    assert_equal [ a.id, b.id ], bucket
    assert_equal inbox.id, elsewhere.reload.category_id
  end

  test "unknown, blank and non-numeric ids are dropped" do
    a = build_session(created_at: 2.hours.ago)
    b = build_session(created_at: 1.hour.ago)

    Session.reorder_cards!([ "", nil, "abc", 999_999, b.id.to_s, a.id ], category_id: nil)

    assert_equal [ b.id, a.id ], bucket
  end

  test "a duplicated id is honored once" do
    a = build_session(created_at: 2.hours.ago)
    b = build_session(created_at: 1.hour.ago)

    Session.reorder_cards!([ b.id, a.id, b.id ], category_id: nil)

    assert_equal [ b.id, a.id ], bucket
  end

  test "an empty list is a no-op that still reports the bucket" do
    a = build_session(created_at: 2.hours.ago)
    b = build_session(created_at: 1.hour.ago)

    assert_equal [ b.id, a.id ], Session.reorder_cards!([], category_id: nil)
    assert_equal [ b.id, a.id ], bucket
  end

  test "positions are written in batches when a bucket is larger than one batch" do
    original = SessionCardOrder::WRITE_BATCH_SIZE
    SessionCardOrder.send(:remove_const, :WRITE_BATCH_SIZE)
    SessionCardOrder.const_set(:WRITE_BATCH_SIZE, 2)

    ids = 5.times.map { |i| build_session(created_at: (10 - i).hours.ago).id }
    Session.reorder_cards!(ids, category_id: nil)

    assert_equal ids, bucket
    assert_equal (0...5).to_a, Session.where(id: ids).order(:sort_order).pluck(:sort_order)
  ensure
    SessionCardOrder.send(:remove_const, :WRITE_BATCH_SIZE)
    SessionCardOrder.const_set(:WRITE_BATCH_SIZE, original)
  end
end
