# frozen_string_literal: true

# A top-level group on Your board (`/?view=board_v2`).
#
# Flat and entirely manual: a person creates a category, names it, and drags
# sessions into it. Nothing assigns a session to a category on its own — there
# is no categorizer, no heuristic and no suggestion. A session with no category
# is drawn in the board's Uncategorized group.
#
# Three bits of per-category presentation state live on the row:
#
# * `position` — the order categories are drawn in, rewritten by dragging a
#   category's header (BoardCategories::Reorder).
# * `collapsed` — the section shows its header only. Stored here, not in the
#   browser, so it survives a reload and follows the operator between devices.
# * `visibility` / `snoozed_until` — the same board-visibility pair a session
#   carries, read through the same BoardVisibilityState predicates, applied to
#   the category as a unit: a snoozed or backlogged category leaves the board
#   with every session in it and comes back on its own when the snooze runs out.
#   It never writes its sessions' own visibility, and like every visibility it is
#   presentation only — nothing about when any of its sessions runs changes.
class BoardCategory < ApplicationRecord
  include BoardVisibilityState

  NAME_MAX_LENGTH = 60

  # A category is snoozed until a time or backlogged; "hidden" is a session's
  # fourth state and has no use on a category the operator named themselves.
  VISIBILITIES = [
    SessionVisibility::VISIBLE, SessionVisibility::SNOOZED, SessionVisibility::BACKLOGGED
  ].freeze

  # Deleting a category leaves its sessions in Uncategorized: the foreign key is
  # ON DELETE SET NULL, so the database does it with no Rails-side sweep.
  has_many :sessions, dependent: nil

  validates :name, presence: true, length: { maximum: NAME_MAX_LENGTH }
  validates :name, uniqueness: { case_sensitive: false }
  validates :collapsed, inclusion: { in: [ true, false ], message: "must be true or false" }
  validates :visibility, inclusion: { in: VISIBILITIES, message: "%{value} is not a valid category visibility" }
  validates :snoozed_until, presence: { message: "is required when a category is snoozed" },
            if: -> { visibility == SessionVisibility::SNOOZED }

  before_validation { self.name = name.to_s.squish }
  # Bottom of the board. A race between two creates gives both the same
  # position, which only ties their order (broken by id) until the next drag.
  before_create { self.position = (self.class.order(position: :desc).pick(:position) || -1) + 1 }

  # A reorder writes positions without callbacks and announces itself.
  after_commit -> { BoardCategories::AnnounceLayoutChange.call },
    if: -> { destroyed? || previously_new_record? || saved_change_to_name? || saved_change_to_visibility? || saved_change_to_snoozed_until? }

  scope :ordered, -> { order(:position, :id) }
end
