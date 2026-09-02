# frozen_string_literal: true

# One item on the agent fleet's work backlog: a GitHub issue the issue work gate
# cleared, ranked, waiting for the groomer to start it — or, once it is no longer
# waiting, the record of what became of it.
#
# WHY THIS IS A TABLE AND NOT A FILE
#
# The queue lived as `WORK_BACKLOG.json` in `tadasant/tadasant-internal`, and
# every append and every pull cost a pull request and a CI run. This table is the
# same queue with the same ranking rules (WorkBacklog::Ranking), reachable by a
# gate or a groomer in one call. The spec the file followed, `WORK_BACKLOG.md`,
# is still the spec; what changed is where the rows live and who has to do the
# arithmetic.
#
# THE STATUS LIFECYCLE, AND WHY NOTHING IS DELETED
#
#   queued  → the item is waiting. The only status the ranking looks at.
#   started → a pull or a "start now" spawned a session for it; `started_session`
#             is that session, `started_by_session` the session that pulled.
#   removed → taken off the queue without being started: an issue that died before
#             its turn, or a human's decision. `removal_reason` says which and
#             `removed_by` says who. "Removed" still means gone from the queue.
#
# The file deleted a pulled item, so the history of what got started lived only
# in the groomer's reports. Keeping the rows is what lets the Issues view chart
# the queue over time and lets "what did the backlog produce" be a query.
#
# WHO MAY DO WHAT
#
# Appending, pulling, and the mechanical re-ranking those imply are agent work
# and reachable over MCP (the `work_backlog` tool group). Pinning an item, hand-
# placing it, and removing it by judgement are a human's, and have no MCP path
# at all — they exist only on the session-authenticated REST controller, whose
# form the Issues view will grow. The one removal an agent may make is the
# mechanical one: an item whose issue is found dead at pull time, with the reason
# drawn from MECHANICAL_REMOVAL_REASONS rather than typed.
class WorkBacklogItem < ApplicationRecord
  QUEUED = "queued"
  STARTED = "started"
  REMOVED = "removed"
  STATUSES = [ QUEUED, STARTED, REMOVED ].freeze

  COSTS = %w[small medium large].freeze
  SCOPE_DIRECTIONS = %w[convergent divergent].freeze

  # How the row arrived. `import` is the one-time backfill of the JSON file;
  # `mcp` is a gate calling append_work_backlog_item; `api` is a POST to
  # /api/v1/work_backlog_items. Stamped by the writer, never accepted from a caller.
  IMPORT = "import"
  MCP = "mcp"
  API = "api"
  ADDED_VIA = [ IMPORT, MCP, API ].freeze

  # The two writers that may create an item with no issue behind it. The groomer
  # spawns a session straight from `prompt`, with no issue to re-check and no gate
  # verdict behind it, so `issue_url: nil` is exactly the shape ungated work would
  # take to reach the fleet. A human standing behind the item personally, or the
  # one-time migration, is the whole carve-out.
  ISSUELESS_ADDED_BY = %w[human queue-migration].freeze

  # The reasons a PULL may remove an item without a human: each is a fact about
  # the issue that the puller re-checked on GitHub, not a judgement about whether
  # the work is worth doing. Anything else is a human's call and goes through the
  # REST `remove` action with a free-text reason.
  MECHANICAL_REMOVAL_REASONS = %w[issue_closed issue_has_open_pr session_already_working trust_failed].freeze

  # The keys in the file's item schema that have a column here. Everything else
  # in an item — ratings, prompt, notes, gate_session, and whatever the gate adds
  # next — rides in `payload`.
  PROMOTED_KEYS = %w[id issue repo surface title kind scope_direction estimated_cost gate_verdict
                     decided_at added_at added_by precedence pinned].freeze

  # Postgres `integer`. A hand-placed precedence past this would raise at the
  # UPDATE rather than at validation.
  PRECEDENCE_RANGE = (-(2**31)..(2**31 - 1))

  # Session validates its title at this length; a title written past it leaves
  # the session unable to save through its own state machine.
  SESSION_TITLE_MAX = 100

  MAX_URL_LENGTH = 2048
  MAX_PAYLOAD_BYTES = 64.kilobytes

  belongs_to :writing_session, class_name: "Session", optional: true
  belongs_to :started_session, class_name: "Session", optional: true
  belongs_to :started_by_session, class_name: "Session", optional: true

  validates :key, presence: true, length: { maximum: 200 }
  validates :repo, presence: true, format: { with: %r{\A[\w.-]+/[\w.-]+\z}, message: "must be owner/name" }
  validates :surface, presence: true, length: { maximum: 200 }
  validates :title, presence: true, length: { maximum: 1000 }
  validates :kind, presence: true, length: { maximum: 100 }
  validates :scope_direction, inclusion: { in: SCOPE_DIRECTIONS }
  validates :estimated_cost, inclusion: { in: COSTS }
  validates :status, inclusion: { in: STATUSES }
  validates :added_via, inclusion: { in: ADDED_VIA }
  validates :added_by, presence: true, length: { maximum: 100 }
  validates :added_at, presence: true
  validates :issue_url, length: { maximum: MAX_URL_LENGTH }, allow_nil: true
  validates :precedence, numericality: { only_integer: true, in: PRECEDENCE_RANGE }
  validates :removal_reason, presence: true, if: :removed?
  validate :issueless_items_need_a_prompt_and_a_human
  validate :payload_must_be_an_object
  validate :payload_must_be_within_size

  scope :queued, -> { where(status: QUEUED) }
  scope :started, -> { where(status: STARTED) }
  scope :removed, -> { where(status: REMOVED) }
  scope :unpinned, -> { where(pinned: false) }
  scope :pinned_items, -> { where(pinned: true) }
  # The queue's order: highest precedence first, oldest first within a tie, and
  # the row id as the final tiebreak so the order is total. Matches the file's
  # "sort by precedence descending, then added_at ascending".
  scope :in_rank_order, -> { order(precedence: :desc, added_at: :asc, id: :asc) }
  # Started items whose session is still alive. `in_flight` is what the groomer's
  # WIP ceiling counts — sessions THIS backlog produced, not the whole spot queue.
  scope :in_flight, -> {
    started.where(started_session_id: Session.where.not(status: [ :archived, :failed ]).select(:id))
  }

  def queued? = status == QUEUED
  def started? = status == STARTED
  def removed? = status == REMOVED
  def issueless? = issue_url.blank?

  # --- payload readers ------------------------------------------------------

  def ratings = payload_hash["ratings"].is_a?(Hash) ? payload_hash["ratings"] : {}
  def prompt = payload_hash["prompt"].presence
  def notes = payload_hash["notes"].presence
  def gate_session_url = payload_hash["gate_session"].presence

  # The GitHub issue number, when the key names one.
  def issue_number
    match = issue_url.to_s.match(%r{/issues/(\d+)\z})
    match && match[1].to_i
  end

  # What a session spawned for this item is told. The issue is the durable
  # record wherever there is one, so the prompt is the URL plus the ask; an
  # issueless item carries its ask verbatim in `prompt` and that is the whole
  # prompt. A `prompt` beside an issue (a human's note on how to approach it) is
  # appended after the URL rather than replacing the ask.
  def session_prompt
    return prompt.to_s if issueless?

    [ issue_url, prompt || "Please implement this." ].join("\n\n")
  end

  # The title the groomer gave every session it pulled: "Implement zimmer#498
  # (…)". Cosmetic now — `started_session_id` is the countable key — but it is
  # what a human scanning the Ranked view expects to see. Budgeted so the
  # prefix always survives and the whole thing fits Session's title limit.
  def session_title
    short = repo.to_s.split("/").last
    label = issue_number ? "#{short}##{issue_number}" : key
    prefix = "Implement #{label} ("
    room = SESSION_TITLE_MAX - prefix.length - 1
    return prefix.chomp(" (").truncate(SESSION_TITLE_MAX) if room < 4

    "#{prefix}#{title.to_s.truncate(room, omission: "…")})"
  end

  # --- transitions -----------------------------------------------------------

  # Mark this item started by `session`. The caller holds the ranking lock and
  # has already checked the row is queued (WorkBacklog::Start does both).
  def mark_started!(session:, by:, now: Time.current)
    update!(status: STARTED, started_session: session, started_by_session: by, started_at: now)
  end

  # Take the item off the queue. `by` names who — "human" from the REST action,
  # the pulling session or "api"/"mcp" from a pull — and `reason` says why. A
  # human's reason is free text; an agent's is one of MECHANICAL_REMOVAL_REASONS,
  # which WorkBacklog::Pull enforces before it gets here.
  def remove!(reason:, by:, now: Time.current)
    update!(status: REMOVED, removal_reason: reason, removed_by: by, removed_at: now)
  end

  # A human's hand-placement: the item goes exactly where they put it and stays
  # there. A pinned item is never re-banded, renumbered or un-pinned by an agent.
  def pin!(precedence:)
    update!(precedence: Integer(precedence), pinned: true)
  end

  # Release a pin. The caller re-ranks afterwards so the item lands back inside
  # the band its cost implies.
  def unpin!
    update!(pinned: false)
  end

  # The band this item's cost puts it in, and whether it currently sits inside it.
  def band = WorkBacklog::Ranking.band_for(estimated_cost)
  def in_band? = band.include?(precedence)

  # The one JSON shape every surface renders: REST index/show, the MCP read tool,
  # the pull receipts. Promoted columns first, then the payload readers, then
  # the whole payload so a reader that only knows the file's schema loses nothing.
  def as_api_json
    {
      id: id,
      key: key,
      issue_url: issue_url,
      repo: repo,
      surface: surface,
      title: title,
      kind: kind,
      scope_direction: scope_direction,
      estimated_cost: estimated_cost,
      ratings: ratings,
      gate_verdict: gate_verdict,
      gate_session: gate_session_url,
      decided_at: decided_at&.iso8601,
      added_at: added_at&.iso8601,
      added_by: added_by,
      added_via: added_via,
      precedence: precedence,
      pinned: pinned,
      status: status,
      prompt: prompt,
      notes: notes,
      writing_session_id: writing_session_id,
      started_session_id: started_session_id,
      started_by_session_id: started_by_session_id,
      started_at: started_at&.iso8601,
      removed_at: removed_at&.iso8601,
      removed_by: removed_by,
      removal_reason: removal_reason,
      payload: payload
    }
  end

  private

  def payload_hash
    payload.is_a?(Hash) ? payload : {}
  end

  def issueless_items_need_a_prompt_and_a_human
    return unless issueless?

    errors.add(:prompt, "is required for an item with no issue") if prompt.blank?
    unless ISSUELESS_ADDED_BY.include?(added_by)
      errors.add(:added_by, "must be one of #{ISSUELESS_ADDED_BY.join(', ')} for an item with no issue " \
                            "— an idea with no issue behind it belongs in a GitHub issue, where it gets rated")
    end
  end

  def payload_must_be_an_object
    errors.add(:payload, "must be a JSON object") unless payload.is_a?(Hash)
  end

  def payload_must_be_within_size
    return unless payload.is_a?(Hash)

    bytes = payload.to_json.bytesize
    errors.add(:payload, "is too large (#{bytes} bytes; the limit is #{MAX_PAYLOAD_BYTES})") if bytes > MAX_PAYLOAD_BYTES
  end
end
