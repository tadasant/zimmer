# A user-created organizational category for grouping session cards on the
# dashboard. Categories are global (Zimmer is single-operator) and
# ordered by their integer +position+. Sessions reference a category via the
# nullable +category_id+ column; a NULL value means the session is "Uncategorized".
#
# The optional +description+ explains what belongs in the category. It is not shown
# on the dashboard, but it is fed to the auto-categorization inference so new
# sessions can be matched against a category's intent, not just its name.
class Category < ApplicationRecord
  has_many :sessions, dependent: :nullify

  validates :name, presence: true, length: { maximum: 100 }, uniqueness: { case_sensitive: false }
  validates :description, length: { maximum: 1000 }, allow_blank: true

  scope :ordered, -> { order(position: :asc, created_at: :asc) }

  # The sentinel id the dashboard sends for the "Uncategorized" section, which is
  # the category_id = nil bucket and therefore has no Category row. Its slot in the
  # stack is persisted on AppSetting#uncategorized_position instead of a
  # Category#position, so it can interleave with real categories.
  UNCATEGORIZED_SENTINEL = "uncategorized"

  # Normalize editable text before validation so every write path (web controller,
  # REST API, console) stores the same canonical form: names are trimmed and a
  # blank description collapses to NULL rather than an empty string.
  before_validation :normalize_name, :normalize_description

  # Assigns the next position (appended to the end) when not explicitly set.
  before_validation :assign_default_position, on: :create

  # Persist a new top-to-bottom ordering of the whole category stack. Accepts the
  # ordered list of section ids (as sent by the dashboard drag-and-drop / context
  # menu, or the REST API) and rewrites each category's +position+ to its index in
  # that list. The special +UNCATEGORIZED_SENTINEL+ ("uncategorized") writes its
  # index to AppSetting#uncategorized_position so the Uncategorized section
  # interleaves with real categories.
  #
  # Zero/blank entries are dropped before indexing so positions stay contiguous;
  # unknown ids touch no rows; any category omitted from the list keeps its existing
  # position (Category.ordered breaks any incidental ties by created_at). Returns the
  # cleaned, ordered id list (strings, with the sentinel preserved verbatim).
  def self.reorder!(ids)
    cleaned_ids = Array(ids).map(&:to_s).select do |id|
      id == UNCATEGORIZED_SENTINEL || id.to_i != 0
    end

    transaction do
      cleaned_ids.each_with_index do |id, index|
        if id == UNCATEGORIZED_SENTINEL
          AppSetting.editable.update!(uncategorized_position: index)
        else
          where(id: id.to_i).update_all(position: index)
        end
      end
    end

    cleaned_ids
  end

  private

  def normalize_name
    self.name = name.strip if name.is_a?(String)
  end

  def normalize_description
    self.description = description.strip.presence if description.is_a?(String)
  end

  def assign_default_position
    self.position ||= (Category.maximum(:position) || -1) + 1
  end
end
