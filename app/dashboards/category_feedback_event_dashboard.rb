require "administrate/base_dashboard"

class CategoryFeedbackEventDashboard < Administrate::BaseDashboard
  # The categorization eval corpus: what the categorizer answered, the context it
  # answered from, and what a human said instead. Readable here because the
  # Tadasant deployment has no shell on the box — /supervisor is how an operator
  # reads Zimmer's own tables.
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    session: Field::BelongsTo,
    kind: Field::String,
    auto_category: Field::BelongsTo,
    auto_category_name: Field::String,
    corrected_category: Field::BelongsTo,
    corrected_category_name: Field::String,
    # Up to 8 KB of transcript: the exact string the model was shown, which is
    # what makes replay hermetic. On the show page only — see COLLECTION_ATTRIBUTES.
    context_snapshot: Field::Text,
    context_source: Field::String,
    title_requested: Field::Boolean,
    raw_answer: Field::Text,
    model: Field::String,
    prompt_version: Field::String,
    source: Field::String,
    candidate_names: Field::String.with_options(searchable: false),
    # The last verdict a replay of the current config gave this row.
    replayed_at: Field::DateTime,
    replay_category: Field::BelongsTo,
    replay_category_name: Field::String,
    replay_raw_answer: Field::Text,
    replay_model: Field::String,
    replay_prompt_version: Field::String,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # Deliberately without `context_snapshot` and the raw answers: an index page
  # carrying 8 KB per row is a slow page nobody can read, and what an operator
  # comes here for is the answer, the correction and the replay verdict.
  COLLECTION_ATTRIBUTES = %i[
    id
    kind
    session
    auto_category_name
    corrected_category_name
    replay_category_name
    created_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  # Append-only. Every row is evidence of what a model or a human actually did,
  # and a corpus somebody can hand-author is not evidence of anything. The
  # `replay_*` columns are written by CategorizationReplayJob, which is reached
  # from the categorization page, not from here.
  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {
    corrections: ->(resources) { resources.where(kind: CategoryFeedbackEvent::CORRECTION) },
    declines: ->(resources) { resources.where(kind: CategoryFeedbackEvent::UNCATEGORIZED) },
    replayed: ->(resources) { resources.where.not(replayed_at: nil) }
  }.freeze
end
