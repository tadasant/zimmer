# frozen_string_literal: true

# Where a session card sits inside its dashboard section.
#
# == Ordinal within a bucket
#
# `sort_order` ranks the sessions of one bucket — a category, or the Uncategorized
# bucket of `category_id IS NULL` — ascending, and the category grid orders every
# section by `sort_order ASC, created_at DESC, id DESC`. Unlike `SessionPrecedence`'s
# scale, the values carry no meaning of their own: only their order within the bucket
# does, and a value never needs to be compared across buckets.
#
# == A bucket nobody has reordered is newest-first
#
# The column defaults to 0, and a row nothing has ever placed holds that 0, so a bucket
# of them is one big tie that `created_at DESC` decides: newest first.
#
# == An arrival goes on top without moving anyone
#
# A session that lands in a bucket without saying where — created there, re-categorized
# by the auto-categorizer or `set_category`, or orphaned by a deleted category — takes
# one below the bucket's current minimum. It is on top, like a new session always was,
# and no other row is rewritten to make room. That matters because of how a reorder
# writes (below): it keeps the bucket's existing values and only reshuffles them, which
# only works while the values are distinct. An arrival at a fixed 0 would collide with a
# reordered bucket's head and force a renumber of the whole bucket on the next drag.
#
# == A reorder rewrites what moved, not the bucket
#
# `reorder_cards!` works out the bucket's new order and then hands the bucket's own
# values back out along it, lowest first. Only cards whose rank changed get a new value:
# a drag from rank 40 to rank 0 rewrites 41 rows, not the thousands of archived
# sessions in the same bucket. Only when the values are not distinct — an untouched
# bucket's ties at 0, or two arrivals that raced for the same minimum — does it fall
# back to renumbering the bucket 0..N-1, and after that once it has no reason to again.
#
# == A drag moves one card, next to its neighbour
#
# The ids a drop sends are the section's *current page*, as the browser holds it — and
# the browser does not always agree with the server about which cards are on it. A
# real-time broadcast prepends a new session to a grid that is showing page 2; a
# deleted category's cards are streamed into Uncategorized wherever the reader is.
# Reading positions off the whole posted list would let one such card drag the others
# with it onto another page. So when the caller names the card that moved (the
# dashboard always does), only that card moves: it goes immediately above the card
# below it in the posted list, or immediately below the card above it when it was
# dropped last. Every other card keeps its place — on this page, other pages, and in the
# pinned Starred group, whose cards are still in the bucket but render elsewhere.
#
# Without a moved card (a REST or MCP caller rearranging several at once), the named
# cards are dealt back into the slots they already hold, in the order given, and every
# other card still keeps its place.
#
# == It is global, not per-viewer
#
# Zimmer is a single circle of trust with no `User` model, so there is no principal to
# hang a per-viewer order on. The order lives on the session row and everyone sees the
# same board — the same reasoning that puts `Category#position` on the category.
module SessionCardOrder
  extend ActiveSupport::Concern

  # How many (id, position) pairs one UPDATE carries. A renumber of the Uncategorized
  # bucket on a busy install is thousands of rows; a drag is a handful.
  WRITE_BATCH_SIZE = 500

  included do
    before_save :place_arriving_card_on_top

    # The dashboard's card order within a section. `id DESC` is a stabilizer, not a
    # preference: two sessions created in the same millisecond would otherwise come
    # back in whatever order the planner chose, and `reorder_cards!` reads this same
    # order to work out where everything currently is.
    scope :card_ordered, -> { order(sort_order: :asc, created_at: :desc, id: :desc) }
  end

  private

  # A card arriving in a bucket — created in it, or moved into it — goes on top. A
  # caller that names a sort_order in the same save is placing the card itself and wins.
  def place_arriving_card_on_top
    return unless new_record? || will_save_change_to_category_id?
    return if will_save_change_to_sort_order?

    self.sort_order = self.class.card_order_above(category_id, excluding: id)
  end

  class_methods do
    # Persist a new order for the cards a dashboard section is showing.
    #
    # @param ids [Array] the section's cards, top-to-bottom, as the caller sees them.
    #   Ids that are not in the destination bucket are ignored.
    # @param category_id [Integer, nil] the destination bucket; nil is Uncategorized.
    # @param moved_session_id [Integer, nil] the card that was dragged. When given, and
    #   named in `ids`, only that card moves, placed next to its neighbour in `ids`. If
    #   it belongs to another category it is moved into this one first, so a
    #   cross-section drag persists its category and its position in one transaction.
    # @return [Array<Integer>] the destination bucket's full order after the write.
    def reorder_cards!(ids, category_id:, moved_session_id: nil)
      posted = Array(ids).filter_map { |id| Integer(id.to_s, exception: false) }.uniq
      moved_id = moved_session_id && Integer(moved_session_id.to_s, exception: false)

      transaction do
        moved = moved_id && find_by(id: moved_id)
        # Both sections a cross-section drag touches: the one it lands in, and the one it
        # leaves, whose moved card this transaction is about to write.
        lock_card_buckets!([ category_id, *(moved ? [ moved.category_id ] : []) ])

        moved.update!(category_id: category_id) if moved && moved.category_id != category_id

        current = where(category_id: category_id).card_ordered.pluck(:id, :sort_order)
        bucket = current.map(&:first)
        posted &= bucket

        final =
          if moved_id && posted.include?(moved_id)
            move_card_next_to_neighbour(bucket, moved_id, posted)
          else
            deal_cards_into_own_slots(bucket, posted)
          end

        write_card_sort_orders(final, current, category_id)
        final
      end
    end

    # The sort_order that puts a card above everything in a bucket: one below its
    # minimum, or 0 in an empty bucket.
    def card_order_above(category_id, excluding: nil)
      scope = where(category_id: category_id)
      scope = scope.where.not(id: excluding) if excluding
      lowest = scope.minimum(:sort_order)
      lowest.nil? ? 0 : lowest - 1
    end

    # Put a deleted category's cards on top of Uncategorized, keeping the order they had
    # in the category. Called from Category's before_destroy, because the association's
    # `dependent: :nullify` moves them with an `update_all` the arrival callback never
    # sees — without this they would carry their old category's ranks into a bucket
    # they were never ranked in.
    def place_orphans_on_top_of_uncategorized!(category_id)
      orphans = where(category_id: category_id).card_ordered.pluck(:id)
      return if orphans.empty?

      base = card_order_above(nil) - orphans.size + 1
      # Still in the doomed category at this point: the nullify runs after this.
      write_card_values(orphans.each_with_index.map { |id, index| [ id, base + index ] }, category_id: category_id)
    end

    private

    # Two drags on one section at once would each read the bucket, then write values
    # computed from what the other is about to overwrite. A transaction-scoped advisory
    # lock per bucket serializes them; drags on unrelated sections do not wait. The keys
    # are taken in sorted order, so two cross-section drags going opposite ways between
    # the same pair of sections queue behind each other instead of deadlocking.
    #
    # Arrivals (a create, a category change) deliberately take no lock: that would put
    # every session create behind the drags and the other creates in its bucket for the
    # length of whatever transaction it runs in. The cost of not locking is that two
    # arrivals in the same instant can tie, and a tie is repaired by one renumber on the
    # bucket's next drag — while the UPDATE's bucket guard keeps a card that changed
    # category mid-drag from being handed a rank in the bucket it just left.
    def lock_card_buckets!(category_ids)
      category_ids.uniq.map { |id| "session_card_order:#{id || 'uncategorized'}" }.sort.each do |key|
        connection.execute(sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtext(?))", key ]))
      end
    end

    # Take the moved card out and put it back immediately above the nearest posted card
    # below it, or immediately below the nearest posted card above it when there is none
    # below. The card below is preferred because the strays a page can hold — a
    # broadcast's new session, a deleted category's orphans — arrive at the top of the
    # grid, so the neighbour above is the one likelier to be a card the server would
    # render somewhere else entirely.
    def move_card_next_to_neighbour(bucket, moved_id, posted)
      rest = bucket - [ moved_id ]
      position = posted.index(moved_id)

      # `posted` is de-duplicated and limited to the bucket, so both are in `rest`.
      below = posted[position + 1]
      above = posted[position - 1] if position.positive?

      index =
        if below then rest.index(below)
        elsif above then rest.index(above) + 1
        end
      return bucket if index.nil?

      rest.insert(index, moved_id)
    end

    # Deal the slots the posted cards already occupy back out in the posted order.
    # Every other card keeps the index it had.
    def deal_cards_into_own_slots(bucket, posted)
      return bucket if posted.empty?

      slot_of = bucket.each_with_index.to_h
      slots = posted.map { |id| slot_of[id] }.sort
      final = bucket.dup
      posted.each_with_index { |id, index| final[slots[index]] = id }
      final
    end

    # Give `final` strictly increasing values, rewriting as few rows as possible. The
    # bucket's own values are reused, lowest first along the new order, so a card whose
    # rank did not change keeps its value and is not written. If the values are not
    # distinct there is no order-preserving way to reuse them, and the bucket is
    # renumbered 0..N-1 instead.
    def write_card_sort_orders(final, current, category_id)
      values = current.map(&:last)
      targets = values.each_cons(2).all? { |a, b| a < b } ? values : (0...values.size).to_a
      was = current.to_h

      pairs = final.each_with_index.filter_map do |id, index|
        [ id, targets[index] ] unless was[id] == targets[index]
      end
      write_card_values(pairs, category_id: category_id)
    end

    # One UPDATE per batch rather than `update!` per row: a position is presentation
    # state, and running the model callbacks would bump `updated_at` on every card and
    # fire a card broadcast for each — a storm of re-renders for a move the client has
    # already made in the DOM. `sanitize_sql_array` quotes every value into the two
    # array literals, and every value is an Integer from `pluck` or arithmetic on one.
    #
    # Only rows still in `category_id` are written. A rank means nothing outside the
    # bucket it was computed for, and a card can leave the bucket between the read and
    # this write (a `set_category`, the auto-categorizer) — Postgres re-checks the
    # predicate against the row it waited for, so that card is skipped, not mis-ranked.
    def write_card_values(pairs, category_id:)
      pairs.each_slice(WRITE_BATCH_SIZE) do |slice|
        ids, positions = slice.transpose
        connection.execute(sanitize_sql_array([ <<~SQL.squish, ids, positions, category_id ]))
          UPDATE sessions AS s SET sort_order = v.sort_order
          FROM unnest(ARRAY[?]::bigint[], ARRAY[?]::integer[]) AS v(id, sort_order)
          WHERE s.id = v.id AND s.category_id IS NOT DISTINCT FROM ?
        SQL
      end
    end
  end
end
