# frozen_string_literal: true

# The append-only record of what the auto-categorizer answered, and of the human
# corrections to it (tadasant/zimmer#16).
#
# Three kinds of row, and the distinction between the first two matters as much
# as the distinction from the third:
#
#   * +auto_assigned+  — the categorizer picked a category and wrote it.
#   * +uncategorized+  — the categorizer declined (NONE, a blank answer, or an
#     answer that matched no candidate). A pile of these is a DIFFERENT failure
#     from mis-sorting: it says the categories under-cover the work, not that
#     they are confusable.
#   * +correction+     — a human moved a session that one of the above had
#     already ruled on. This is the only labelled data Zimmer produces, and
#     before this table it was destroyed by the +UPDATE+ that created it.
#
# Every row carries +context_snapshot+: the exact string the model was shown.
# That is what makes replay hermetic — +CategorizationReplayJob+ re-scores
# stored strings, so it neither re-reads a transcript +TranscriptArchiveJob+ may
# have archived nor depends on the session still existing.
#
# Rows are written by +SessionTitleJob+ (through +CategorizationService+) and by
# +Session#record_category_correction+. Nothing updates a row afterwards except
# the +replay_*+ columns, which hold the last verdict the CURRENT config gave
# that row — so "does this config still get it wrong" is one query, not a
# re-run.
class CategoryFeedbackEvent < ApplicationRecord
  AUTO_ASSIGNED = "auto_assigned"
  UNCATEGORIZED = "uncategorized"
  CORRECTION = "correction"
  KINDS = [ AUTO_ASSIGNED, UNCATEGORIZED, CORRECTION ].freeze

  # The kinds a correction can be recorded against: a session the categorizer
  # has actually ruled on. A session no inference ever touched teaches nothing —
  # there is no answer to disagree with — so filing its first manual assignment
  # here would pad the corpus with rows replay can neither score nor learn from.
  INFERENCE_KINDS = [ AUTO_ASSIGNED, UNCATEGORIZED ].freeze

  # Where a correction came from, for the audit half of this record. Not
  # validated against a list: a surface that forgets to name itself should show
  # up as UNATTRIBUTED rather than raise on the operator's drag.
  WEB_UI = "web_ui"
  API = "api"
  MCP = "mcp"
  UNATTRIBUTED = "unattributed"

  # How many corrections the eval corpus hands back by default.
  DEFAULT_CORPUS_LIMIT = 25

  # The columns that carry text bodies: the ≤8 KB snapshot and the two raw
  # answers. A page or a scorecard needs none of them, and 25 rows of snapshot is
  # 200 KB read for nothing, so readers that only render verdicts select around
  # them with #without_bodies. Replay is the one reader that needs the snapshot.
  BODY_COLUMNS = %w[context_snapshot raw_answer replay_raw_answer].freeze

  # The session and the categories are all nullable and all nullify on delete:
  # the corpus outlives them, which is the whole reason it is a table rather
  # than a blob on the session. The denormalized names are what keeps a row
  # readable after its category is gone.
  belongs_to :session, optional: true
  belongs_to :auto_category, class_name: "Category", optional: true
  belongs_to :corrected_category, class_name: "Category", optional: true
  belongs_to :replay_category, class_name: "Category", optional: true

  validates :kind, inclusion: { in: KINDS }

  scope :corrections, -> { where(kind: CORRECTION) }
  scope :inference_outcomes, -> { where(kind: INFERENCE_KINDS) }
  scope :newest_first, -> { order(id: :desc) }
  scope :without_bodies, -> { select(column_names - BODY_COLUMNS) }

  # One row per session: the latest by id. A row whose session has been deleted
  # has no session to group by, so it stands alone (grouped by its own negated
  # id, which no real session id can collide with).
  scope :latest_per_session, lambda {
    where(id: unscoped.merge(all)
      .select("DISTINCT ON (COALESCE(session_id, -id)) id")
      .reorder(Arel.sql("COALESCE(session_id, -id), id DESC")))
  }

  class << self
    # Record what the categorizer answered, and the context it answered from.
    # Called on both the assign and the decline path, so the corpus holds the
    # declines too.
    #
    # Best-effort: a failure here must never take down titling or
    # categorization, which are the things the operator actually asked for. It
    # logs and returns nil instead.
    def record_inference_outcome!(session:, category:, raw_answer:, context:, context_source:,
                                  title_requested:, model:, prompt_version:, candidates: [])
      create!(
        session: session,
        kind: category ? AUTO_ASSIGNED : UNCATEGORIZED,
        auto_category_id: category&.id,
        auto_category_name: category&.name,
        context_snapshot: context,
        context_source: context_source,
        title_requested: !!title_requested,
        raw_answer: raw_answer,
        model: model,
        prompt_version: prompt_version,
        source: "inference",
        candidate_names: Array(candidates).map(&:name)
      )
    rescue StandardError => e
      Rails.logger.warn "[CategoryFeedbackEvent] could not record inference outcome for session #{session&.id}: #{e.class}: #{e.message}"
      nil
    end

    # Record a human overruling the categorizer, copying the snapshot forward
    # from the inference event it disagrees with so the correction row is a
    # self-contained `(context, wrong answer, right answer)` triple.
    #
    # Returns nil — recording nothing — when the categorizer never ruled on this
    # session. See INFERENCE_KINDS.
    def record_correction!(session:, corrected_category:, source: UNATTRIBUTED)
      inference = latest_inference_for(session)
      return nil if inference.nil?

      create!(
        session: session,
        kind: CORRECTION,
        auto_category_id: inference.auto_category_id,
        auto_category_name: inference.auto_category_name,
        corrected_category_id: corrected_category&.id,
        corrected_category_name: corrected_category&.name,
        context_snapshot: inference.context_snapshot,
        context_source: inference.context_source,
        title_requested: inference.title_requested,
        raw_answer: inference.raw_answer,
        model: inference.model,
        prompt_version: inference.prompt_version,
        source: source.presence || UNATTRIBUTED,
        candidate_names: inference.candidate_names
      )
    rescue StandardError => e
      Rails.logger.warn "[CategoryFeedbackEvent] could not record correction for session #{session&.id}: #{e.class}: #{e.message}"
      nil
    end

    def latest_inference_for(session)
      return nil if session&.id.blank?

      where(session_id: session.id).inference_outcomes.newest_first.first
    end

    # The eval corpus: the most recent correction PER SESSION, newest first.
    #
    # Per session, because a human who moves a card twice has stated one opinion
    # about it, not two — counting both would weight an indecisive afternoon
    # over a month of first-time corrections. The earlier rows stay in the table
    # as the audit trail; they are simply not scored twice.
    #
    # The de-duplication is a `DISTINCT ON` in SQL, so what reaches Ruby is
    # exactly `limit` rows. Chain #without_bodies when the snapshot is not needed.
    def eval_corpus(limit: DEFAULT_CORPUS_LIMIT)
      corrections.latest_per_session.includes(:corrected_category).newest_first.limit(limit)
    end
  end

  # The score a replay produces: how many corrections were scored, and on how
  # many of them the current config now agrees with the human. Deliberately
  # counts only rows that were actually replayed — a corpus half of which has
  # never been scored would otherwise read as 50% wrong.
  Scorecard = Struct.new(:total, :replayed, :correct) do
    def accuracy_pct
      return nil if replayed.to_i.zero?

      ((correct.to_f / replayed) * 100).round
    end

    def unreplayed
      total.to_i - replayed.to_i
    end
  end

  def self.scorecard(events)
    scored = events.reject { |event| event.replay_correct?.nil? }
    Scorecard.new(events.size, scored.size, scored.count(&:replay_correct?))
  end

  # How often the categorizer declined to place a session, over the most recent
  # `window` inference outcomes. This is the OTHER failure: a high decline rate
  # means the categories under-cover the work — no description needs sharpening,
  # a category is missing — and reading it off the same table is what keeps the
  # two from being confused for each other.
  #
  # Read off each session's LATEST outcome, not every attempt: a session left
  # Uncategorized is re-tried on every pause, so counting attempts would let one
  # session that pauses a lot outvote a hundred that were placed first time.
  def self.decline_rate(window: 100)
    recent = inference_outcomes.latest_per_session.newest_first.limit(window).pluck(:kind)
    return nil if recent.empty?

    { sampled: recent.size, declined: recent.count(UNCATEGORIZED) }
  end

  # Whether the replay agreed with the human. Nil when this row has never been
  # replayed, or can no longer be scored — so "not scored" is never silently
  # counted as a miss, or as a hit.
  def replay_correct?
    return nil if replayed_at.blank? || !scorable?

    replay_category_id == corrected_category_id
  end

  # Whether the current config can be judged on this correction at all. Two
  # cases say no, and both would otherwise corrupt the score:
  #
  #   * The corrected category was deleted. The foreign key nulled its id but
  #     the name survives, so comparing ids would score a replay that answers
  #     NONE as agreeing with the human — NULL equal to NULL.
  #   * The corrected category is frozen. Frozen categories are never
  #     candidates, so no config could ever pick it and the row would be a miss
  #     forever, whatever the operator tuned.
  def scorable?
    return false if corrected_category_id.nil? && corrected_category_name.present?
    return false if corrected_category_id && (corrected_category.nil? || corrected_category.is_frozen?)

    true
  end

  # How the answer reads for a human: a name, or the word for "no category".
  def auto_label
    auto_category_name.presence || "Uncategorized"
  end

  def corrected_label
    corrected_category_name.presence || "Uncategorized"
  end

  def replay_label
    return nil if replayed_at.blank?

    replay_category_name.presence || "Uncategorized"
  end
end
