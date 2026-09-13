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
  # Named because the Issues page pre-fills it: a queued row whose GitHub issue
  # has since closed offers this as the removal reason, so a human's discretionary
  # removal of a dead item records the same word the pull would eventually have
  # used. Reading it off MECHANICAL_REMOVAL_REASONS by position would silently
  # pre-fill the wrong reason the day that list is reordered.
  ISSUE_CLOSED_REASON = "issue_closed"

  MECHANICAL_REMOVAL_REASONS = [ ISSUE_CLOSED_REASON, "issue_has_open_pr", "session_already_working", "trust_failed" ].freeze

  # The removal reasons that are FACTS WITH A SHELF LIFE. Both describe something
  # happening elsewhere that the removal expected would finish the work: a pull
  # request already open on the issue, or a session already working it. Nothing
  # re-checks either, so when the PR goes quiet or the session ends, the item is
  # off the queue for a reason that has since expired — `tadasant/zimmer#522` was
  # removed as `issue_has_open_pr` on a PR last touched 2026-08-21.
  #
  # `trust_failed` is deliberately not here: it is a judgement about the thread
  # rather than a fact with an expiry. Nor is `issue_closed`, which is terminal.
  PROVISIONAL_REMOVAL_REASONS = [ "issue_has_open_pr", "session_already_working" ].freeze

  # WHAT THE LIVENESS RE-CHECK FOUND, and why a row that left `queued` needs one.
  #
  # A row leaves `queued` by two routes — a pull starts it, or a pull removes it
  # mechanically — and neither has a way back. Nothing reads the row again, so an
  # expired premise leaves the item neither queued nor worked. Measured
  # 2026-09-11: of 159 open convergent issues across the gated repos, 41 were
  # `started` and 13 had been for four days or more.
  #
  # These states are EVIDENCE, NOT VERDICTS. WorkBacklog::LivenessSweep writes
  # them and does nothing else, because the two cases that matter most cannot be
  # told apart by any mechanical signal — see that class for the 12 rows examined
  # by hand that establish it.
  #
  #   issue_closed          the issue is closed. Resolved; nothing to triage.
  #   pr_open               an open PR referencing it has moved recently. Someone
  #                         is on it, so it is not stranded.
  #   pr_stalled            the only open PRs referencing it have gone quiet for
  #                         LivenessSweep::STALE_PR_AFTER. The removal's premise,
  #                         or the session's, has expired.
  #   pr_merged_issue_open  a merged PR references it and the issue is still
  #                         open. THE AMBIGUOUS ONE: either the PR finished the
  #                         work and forgot the closing keyword, or it fixed part
  #                         on purpose and a real remainder is left. Only reading
  #                         the PR and the current code separates them.
  #   no_pr                 no pull request has ever referenced it. Whatever the
  #                         row was started or removed for produced nothing.
  #   unknown               GitHub could not be read for this issue. Not a
  #                         conclusion; re-examined next pass.
  LIVENESS_ISSUE_CLOSED = "issue_closed"
  LIVENESS_PR_OPEN = "pr_open"
  LIVENESS_PR_STALLED = "pr_stalled"
  LIVENESS_PR_MERGED_ISSUE_OPEN = "pr_merged_issue_open"
  LIVENESS_NO_PR = "no_pr"
  LIVENESS_UNKNOWN = "unknown"
  #   superseded            a NEWER row carries this key, so the triage already
  #                         happened: `append_work_backlog_item` puts an item back
  #                         by creating a fresh row and leaving this one as
  #                         history. Without this, a row re-queued today would go
  #                         on ageing in the stranded count forever and the alert
  #                         below it could never be cleared by the action it asks
  #                         for.
  LIVENESS_SUPERSEDED = "superseded"

  LIVENESS_STATES = [ LIVENESS_ISSUE_CLOSED, LIVENESS_PR_OPEN, LIVENESS_PR_STALLED,
                      LIVENESS_PR_MERGED_ISSUE_OPEN, LIVENESS_NO_PR, LIVENESS_UNKNOWN,
                      LIVENESS_SUPERSEDED ].freeze

  # The two verdicts that mean "nothing for a person to do here". Everything else
  # — including a row nothing has checked yet — is stranded until shown otherwise,
  # which is the honest default for a population whose whole problem was that
  # nobody was looking.
  RESOLVED_LIVENESS_STATES = [ LIVENESS_ISSUE_CLOSED, LIVENESS_PR_OPEN, LIVENESS_SUPERSEDED ].freeze

  # The resolved verdicts that are not expected to change. `pr_open` is resolved
  # but not settled: the PR can go quiet or merge with the issue still open, and
  # either one makes the row stranded again. A closed issue is rarely reopened
  # and a superseded row stays superseded. WorkBacklog::LivenessSweep re-checks
  # these rows only after every other candidate, because the candidate population
  # never shrinks: a candidate whose issue closed stays a candidate for good.
  SETTLED_LIVENESS_STATES = [ LIVENESS_ISSUE_CLOSED, LIVENESS_SUPERSEDED ].freeze

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
  validates :liveness_state, inclusion: { in: LIVENESS_STATES }, allow_nil: true
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
  # THE THREE THINGS A `started` ITEM CAN BE, AND WHY THE LINE IS WHERE IT IS
  #
  # `in_flight` is not only a number on a page: it is the throttle. The groomer
  # pulls `min(PER_RUN_CAP, WIP_CEILING − in_flight)` items a night, so anything
  # counted here that is not actually being worked ratchets the ceiling down and
  # the queue stops draining with no error anywhere.
  #
  # The line is drawn at "will this move without a person": a session that is
  # `running` has a turn on a worker, and one that is `waiting` is queued for a
  # worker or asleep on a wake it armed for itself — both resume on their own.
  # A session in `needs_input` has stopped and handed the work to a human; that
  # is exactly what a session holding a finished PR does when the merge gate has
  # held it or its self-wake budget is spent, and it can sit there for days. So
  # **a session parked holding an open PR is NOT in flight.** It is spending no
  # compute and no agent is advancing it, and counting it lets a handful of
  # finished items hold the whole WIP ceiling shut.
  #
  # That cut lands on the fleet's own protocol rather than beside it: the
  # `open-pr` skill sleeps on a PR that is merely waiting for the merge gate to
  # rate it, which leaves a `waiting` session and stays in flight, and comes to
  # rest in `needs_input` only when a human is what the PR is waiting on.
  scope :in_flight, -> {
    started.where(started_session_id: Session.where(status: [ :running, :waiting ]).select(:id))
  }

  # The SUBSET of `in_flight` whose sessions are dormant on a spot-gate hold:
  # started, `waiting`, and refused at the door by SpotGateService rather than
  # queued for a worker. Reported beside `in_flight`, and deliberately still
  # counted INSIDE it.
  #
  # BOTH of the gate's refusal reasons land here, and a reader must not assume
  # the quota one. `hold!` writes `decision.reason`, which is `at_utilization_limit`
  # OR `fleet_at_cap`, and #held_sessions does not filter on it — so this counts a
  # session waiting on a quota window and one waiting on a free slot alike, which
  # is what `get_spot_policy` already means by "held before a turn". The two
  # invert each other's reading and nothing here can tell them apart: a fleet-cap
  # hold means every slot is taken, so the fleet is BUSY and a pull of zero is
  # healthy; a utilization hold means the fleet is idle behind a budget window and
  # it is not. Anything drawing a conclusion from this number has to ask
  # `get_spot_policy` which ceiling is holding, which is why every surface that
  # renders it says so instead of naming a cause.
  #
  # WHY THIS IS NOT SUBTRACTED FROM `in_flight`, WHICH IS THE WHOLE POINT
  #
  # A held item looks like the parked case — nothing is advancing it, it spends
  # no compute — and the obvious move is to cut it out of the ceiling the way
  # `parked` is cut out. That move is wrong, and the two differ on the property
  # the ceiling is actually about.
  #
  # A parked item is waiting on a PERSON: it can sit for days, and nothing the
  # fleet does brings it back, so counting it lets finished work hold the ceiling
  # shut. A held item is waiting on QUOTA. It is assigned, unfinished work that
  # WILL run: SpotSessionHold re-checks it on its own backoff ladder and starts it
  # without any pull, which is why a sustained hold is a wait and not a deadlock.
  # Dropping it from the ceiling would let the groomer pull fresh items into a
  # fleet that cannot start them — growing the held pile so that everything
  # resumes at once the moment the budget refills, straight back over the pacing
  # curve the hold exists to enforce. The ceiling bounds ASSIGNED work, not
  # running processes, and a held item is assigned.
  #
  # So the defect this fixes is not the arithmetic. It is that a pull of zero
  # could not be read: "the ceiling is full of work being done" and "the ceiling
  # is full of work the gate has never started" are the same number, and the
  # second one is the fleet waiting on a budget window while the report says
  # healthy. This count is what tells them apart.
  #
  # Named `spot_held`, not `held`, because the Issues page already says "held" of
  # an issue carrying `Issues::Board::HOLD_LABEL` — refused by the ISSUE WORK
  # gate, a different gate with a different meaning.
  #
  # SpotSessionHold.held_sessions is the predicate, rather than a second one
  # spelled out here, so this count and the one `get_spot_policy` and /inference
  # report cannot drift. Two consequences come with it and are deliberate: a
  # session also carrying a ceiling pause or an auth-outage park belongs to those
  # populations and is not counted here, and a session held before it was promoted
  # to `priority` still carries the marker (SpotSessionHold#superseded_by_promotion?)
  # and so is still counted. Both match what the operator already reads elsewhere.
  #
  # The first of those has a cost worth naming: a ceiling-paused or auth-parked
  # session is also `waiting` and also being advanced by nobody, so it stays in
  # `in_flight` and is not split out here. This count narrows what "in flight"
  # overstates; it does not close it. See docs/limitations.md.
  scope :spot_held, -> {
    started.where(started_session_id: SpotSessionHold.held_sessions.reorder(nil).select(:id))
  }

  # Started items parked in `needs_input`: nothing is advancing them, and a person
  # is what they are waiting on. Rendered as its own section on the Issues page,
  # because "these are waiting on you" is the answer to "why is the queue not
  # draining", and the old single `in_flight` list hid it inside "what is running".
  #
  # One session shape sits on the wrong side of the line and is left there: a
  # `needs_input` session with an enqueued message will be resumed by the drain
  # with no human involved, so for the minute or two before that happens it reads
  # as parked. Transient, self-correcting, and the alternative is a second query
  # per row on a page that is already several counts deep.
  scope :parked, -> {
    started.where(started_session_id: Session.where(status: :needs_input).select(:id))
  }

  # `in_flight` plus `parked` — every started item whose session has not ended.
  # NOT a synonym for in flight, and not what the WIP ceiling counts. It answers
  # a different question: is this issue already claimed? The GitHub half of the
  # Issues page asks that one, because listing an issue as "nobody is working
  # this" while a session sits on its open PR is its own kind of lie.
  scope :claimed, -> {
    started.where(started_session_id: Session.where.not(status: [ :archived, :failed ]).select(:id))
  }

  # Started items whose session ENDED — archived or failed — since `cutoff`.
  # History, but recent history is the other half of an honest picture of the
  # fleet: without it, a page read an hour after seven items ran and finished
  # shows no trace of them and reads as a fleet that did nothing.
  #
  # Dated from the END, never from `started_at`, and the difference is the whole
  # point. This queue's own premise is that an item can be started on Monday and
  # only finish on Wednesday, because its session parked on a PR in between — so
  # a window measured from the start would drop exactly the long-running items at
  # the moment they finished, which is the failure this list exists to fix.
  #
  # `archived_at` is stamped by the archive transition; `failed` has no timestamp
  # of its own, so `updated_at` is the proxy, and COALESCE keeps one comparison
  # over both. `updated_at` can be nudged by a later write to an ended session,
  # which can only ever pull a stale row INTO the window — visible and harmless,
  # where the reverse would be silent.
  scope :ended_since, ->(cutoff) {
    started.where(started_session_id: Session.where(status: [ :archived, :failed ])
                                             .where("COALESCE(sessions.archived_at, sessions.updated_at) >= ?", cutoff)
                                             .select(:id))
  }

  # The mirror of `ended_since`: started items whose session ended BEFORE
  # `cutoff`. Same COALESCE, same reason for it, opposite comparison — so
  # "finished in the last day" and "ended long enough ago to be worth
  # re-examining" are one reading of when a session ended rather than two.
  scope :ended_before, ->(cutoff) {
    started.where(started_session_id: Session.where(status: [ :archived, :failed ])
                                             .where("COALESCE(sessions.archived_at, sessions.updated_at) < ?", cutoff)
                                             .select(:id))
  }

  # Rows removed for a reason that may since have expired. See
  # PROVISIONAL_REMOVAL_REASONS. The same grace applies to these as to a started
  # row: an item removed a minute ago because a session is already working it has
  # a premise that is still true, and probing it immediately would find no PR yet
  # and report an item somebody is actively working as stranded.
  scope :removed_provisionally, -> { removed.where(removal_reason: PROVISIONAL_REMOVAL_REASONS) }

  # EVERY ROW WORTH RE-CHECKING, by both routes out of `queued`: a `started` row
  # whose session ended before the grace, and a `removed` row whose removal was
  # provisional. An issueless item is excluded — there is no issue to probe, so
  # nothing here could say anything about it.
  #
  # A third way to strand is NOT here and cannot be: an issue with no row at all.
  # Before 2026-08-29 the gate started sessions itself and the migration into this
  # table imported only `queued` items, so that work left nothing to re-check.
  # `tadasant/zimmer#368` sat 37 days that way. Those show up on the Issues page
  # under "In GitHub, not on the queue".
  scope :liveness_candidates, ->(grace: WorkBacklog::LivenessSweep::GRACE, now: Time.current) {
    where.not(issue_url: nil).where(id: ended_before(now - grace))
      .or(where.not(issue_url: nil).where(id: removed_provisionally.where(removed_at: ...(now - grace))))
  }

  # The candidates the re-check has NOT resolved — the honest reading of "this
  # item is going nowhere and someone has to look at it". A row whose issue has
  # closed, or whose PR is moving, is not here; a row nothing has examined yet is.
  scope :stranded, ->(grace: WorkBacklog::LivenessSweep::GRACE, now: Time.current) {
    liveness_candidates(grace: grace, now: now)
      .where("liveness_state IS NULL OR liveness_state NOT IN (?)", RESOLVED_LIVENESS_STATES)
  }

  # Has a later row taken this key over? That is what the triage route leaves
  # behind: `append_work_backlog_item` creates a fresh `queued` row rather than
  # moving this one, so this row's job is done even though its status never
  # changed. Keyed on `id` rather than a timestamp because the append's whole
  # point is that it is a new row.
  def superseded? = self.class.where(key: key).where("id > ?", id).exists?

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

  # The repository the issue lives in, as `owner/name`, when `issue_url` names
  # one. Not always `repo`: that is what a session is checked out for, and the
  # gate sets it apart on purpose when the fix lives elsewhere than the tracking
  # issue, so `issue_number` means nothing paired with it (#1188).
  def issue_repo
    match = issue_url.to_s.match(%r{github\.com/([^/]+/[^/]+)/issues/\d+\z})
    match && match[1]
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
    short = (issue_repo || repo).to_s.split("/").last
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

  # Write down what the liveness re-check concluded, without moving the item.
  # Every outcome except a re-queue lands here — including the ones that mean
  # "leave it alone", because a row nobody has drawn a conclusion about and one
  # deliberately left alone are the same row otherwise, and telling them apart is
  # the whole point of looking.
  def record_liveness!(state, now: Time.current)
    update!(liveness_state: state, liveness_checked_at: now)
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
      liveness_state: liveness_state,
      liveness_checked_at: liveness_checked_at&.iso8601,
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
