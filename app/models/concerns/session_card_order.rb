# frozen_string_literal: true

# Where a session card sits inside its dashboard section.
#
# == Ordinal, unlike precedence
#
# `sort_order` is the opposite of `SessionPrecedence`'s scale. It is a dense 0..N-1
# rank over the sessions in one bucket — a category, or the Uncategorized bucket of
# `category_id IS NULL` — and a reorder rewrites the whole bucket rather than slotting
# a sparse value between two neighbours. Dense is what makes the read side cheap: the
# dashboard's ordering is `sort_order ASC, created_at DESC`, one index-backed sort, no
# window function and no per-section join.
#
# == A never-dragged card still lands where it always did
#
# The column defaults to 0, so every session in a bucket nobody has ever reordered
# ties at 0 and `created_at DESC` decides — newest first, exactly the order the
# dashboard had before any of this existed. The same tie is what keeps a *new* session
# at the top of a bucket that HAS been reordered: it arrives at 0, the reordered
# cards hold 0..N-1, and the tie at 0 against the current head breaks on the newer
# `created_at`. Nothing has to renumber when a session is created.
#
# == A position means nothing outside the bucket it was dealt in
#
# So a card that changes category any other way — the auto-categorizer,
# `set_category`, the MCP and REST equivalents — drops back to 0 and arrives the way a
# new session does: at the top-tie, ordered against it by `created_at`. Without that it
# would carry its old section's rank into the new one and land at an arbitrary depth.
# `reorder_cards!` then places a dragged card properly. Deleting a category resets its
# cards the same way (`Category`'s `before_destroy`), because `dependent: :nullify`
# moves them with an `update_all` that no callback here sees.
#
# == It is global, not per-viewer
#
# Zimmer is a single circle of trust with no `User` model, so there is no principal to
# hang a per-viewer order on. The order lives on the session row and everyone sees the
# same board — the same reasoning that puts `Category#position` on the category.
#
# == The reorder carries global positions, not page-local ones
#
# Each section paginates independently at `SessionsController::SESSIONS_PER_PAGE`, so
# the ids a drop sends are one *page* of a bucket, not the bucket. Treating their
# index in that list as the position would give page 2's cards the ranks 0..49 and
# overwrite page 1.
#
# `reorder_cards!` instead permutes in place: it reads the slots the posted cards
# already occupy in the bucket's order and deals them back out, lowest slot to the
# card the caller put first. A card the caller did not name never moves — not a card
# on another page, and not a favorited card, which is in the bucket but renders in the
# pinned Starred group rather than in the section, so it is *interleaved* with the
# posted ones rather than sitting after them. A card arriving from another section has
# no slot of its own to contribute (its old one belongs to the bucket it left), so it
# is inserted next to whichever posted neighbour the caller placed it against.
module SessionCardOrder
  extend ActiveSupport::Concern

  # How many (id, position) pairs one UPDATE carries. The first reorder in a bucket
  # renumbers every card in it, which on the Uncategorized bucket of a busy install is
  # thousands of rows; later reorders touch only the cards that actually moved.
  WRITE_BATCH_SIZE = 500

  included do
    before_save :reset_card_order_on_category_change

    # The dashboard's card order within a section. `id DESC` is a stabilizer, not a
    # preference: two sessions created in the same millisecond would otherwise come
    # back in whatever order the planner chose, and `reorder_cards!` reads this same
    # order to work out which slots the posted cards hold.
    scope :card_ordered, -> { order(sort_order: :asc, created_at: :desc, id: :desc) }
  end

  private

  # A caller that names a sort_order alongside the category is placing the card itself,
  # and wins; everyone else is moving it without saying where, which means the top.
  def reset_card_order_on_category_change
    return unless will_save_change_to_category_id? && !will_save_change_to_sort_order?

    self.sort_order = 0
  end

  class_methods do
    # Persist a new order for the cards a dashboard section is showing.
    #
    # @param ids [Array] the section's cards, top-to-bottom, as the client sees them.
    #   Ids that are not in the destination bucket are ignored.
    # @param category_id [Integer, nil] the destination bucket; nil is Uncategorized.
    # @param moved_session_id [Integer, String, nil] the card that was dragged, when
    #   the drag crossed sections. Its `category_id` is updated first so it is part of
    #   the destination bucket by the time positions are assigned — one request that
    #   persists both halves of a cross-section move, so neither can land without the
    #   other.
    # @return [Array<Integer>] the destination bucket's full order after the write.
    def reorder_cards!(ids, category_id:, moved_session_id: nil)
      posted = Array(ids).filter_map { |id| Integer(id.to_s, exception: false) }.uniq

      transaction do
        arrived = nil
        if moved_session_id.present?
          moved = find_by(id: Integer(moved_session_id.to_s, exception: false))
          if moved && moved.category_id != category_id
            moved.update!(category_id: category_id)
            arrived = moved.id
          end
        end

        bucket = where(category_id: category_id).card_ordered.pluck(:id)
        posted &= bucket
        next bucket if posted.empty?

        # The card that just crossed into this bucket is sitting at whatever slot its
        # OLD bucket's numbering happens to give it here, which is meaningless — it is
        # placed by its neighbours below instead of contributing a slot of its own.
        incoming = posted.include?(arrived) ? [ arrived ] : []
        settled = bucket - incoming
        resident = posted - incoming

        # Deal the slots the posted cards already occupy back out in the posted order.
        # Every other card in `settled` keeps the index it had.
        slot_of = settled.each_with_index.to_h
        slots = resident.map { |id| slot_of[id] }.sort
        final = settled.dup
        resident.each_with_index { |id, index| final[slots[index]] = id }

        incoming.each { |id| final.insert(insertion_index_for(id, posted, final, slots), id) }

        write_card_sort_orders(final)
        final
      end
    end

    private

    # Where a card arriving from another section goes: immediately after the nearest
    # card the caller placed above it, else immediately before the nearest one below,
    # else at the top of the block the caller named. Anchoring on a neighbour rather
    # than on an index is what keeps a drop onto page 2 on page 2 — the neighbours are
    # page 2's cards, which are still at page 2's slots.
    def insertion_index_for(id, posted, final, slots)
      position = posted.index(id)

      above = posted[0...position].reverse.find { |candidate| final.include?(candidate) }
      return final.index(above) + 1 if above

      below = posted[(position + 1)..].to_a.find { |candidate| final.include?(candidate) }
      return final.index(below) if below

      slots.first || 0
    end

    # Write the positions, skipping rows that already hold theirs.
    #
    # Deliberately one UPDATE per batch rather than `update!` per row: a position is
    # presentation state, and running the model callbacks would bump `updated_at` on
    # every card in the bucket and fire a card broadcast for each — a storm of
    # re-renders for a move the client has already made in the DOM. The ids and
    # positions travel as two bound arrays zipped by `unnest`, never as SQL text.
    def write_card_sort_orders(ordered_ids)
      current = where(id: ordered_ids).pluck(:id, :sort_order).to_h
      changed = ordered_ids.each_with_index.reject { |id, index| current[id] == index }
      return if changed.empty?

      changed.each_slice(WRITE_BATCH_SIZE) do |slice|
        ids, positions = slice.transpose
        connection.execute(sanitize_sql_array([ <<~SQL.squish, ids, positions ]))
          UPDATE sessions AS s SET sort_order = v.sort_order
          FROM unnest(ARRAY[?]::bigint[], ARRAY[?]::integer[]) AS v(id, sort_order)
          WHERE s.id = v.id
        SQL
      end
    end
  end
end
