# frozen_string_literal: true

# What Zimmer can say about whether a session's goal has been met, read off state it
# already records.
#
# A goal is prompt text: AgentSessionJob#build_prompt_with_goal appends it and the
# agent is asked to obey it. This is the other half — the parts of that text a
# machine can read back. Each catalog goal lists its `checks` in config/goals.json,
# and each check is a criterion below, evaluated against:
#
# - `github_pull_request_urls` — the PRs GithubPrUrlHook saw the session open
# - `github_pull_request_statuses` / `_ci_statuses` — Github::PrStatusEvaluator
# - `github_pull_request_goal_facts` — Github::GoalFactsEvaluator: the Verification
#   heading, the checkbox counts and the labels, read off the `gh pr view` the poll
#   pass already makes
#
# ADVISORY, DELIBERATELY
# ----------------------
# The result is reported — on the session page, in `get_session`, in the REST
# session JSON, and tallied by GoalCheckTally — and nothing acts on it. It does not
# fail a session, block an archive, or re-prompt. A wrong enforcement is worse than
# the gap it closes: a check that misreads a PR (a template's commented-out
# checkbox, a repo with no CI, a label withheld on purpose) would trap a finished
# session or refuse to let it end, and the person who notices would be the one
# whose work stalled.
#
# The re-prompt tadasant/zimmer#88 proposed was measured against real resting
# sessions before building it, and the measurement said no: the only session that
# came to rest with an unmet criterion GitHub could see on its own PR had withheld
# the label on purpose while a human decided. GoalCheckTally keeps that population
# counted (`unmet_on_own_pull_request`), so the decision can be taken again on data.
#
# DELEGATED PULL REQUESTS
# -----------------------
# A router hands the work to a session it spawns, and that child is the one whose
# transcript opens the PR, so the PR is recorded on the child. Read on its own
# metadata, every router carrying a PR goal came to rest `unmet` on "no pull
# request recorded" — 50 of the 55 such routers in the first two days had a
# descendant that recorded one. So a session that recorded no PR of its own is
# judged on the PRs recorded by the sessions it spawned, DELEGATION_DEPTH levels
# down, and the result says whose they were (`delegated_session_ids`).
#
# Computed on read, not stored: a pure function of the session's recorded state
# (and its descendants'), so it can never disagree with the PR badge in the header,
# and there is no second copy to go stale. The poll pass is what keeps the inputs
# fresh.
class GoalCheck
  # Criterion key => the label a reader sees. The keys are what config/goals.json
  # names; GoalsConfig refuses to load a goal that names one not listed here.
  CRITERIA = {
    "no_pull_request" => "No pull request opened",
    "pull_request_open" => "A pull request is open or merged",
    "ci_green" => "CI is green",
    "verification_section" => "PR description has a Verification section",
    "verification_boxes_checked" => "Verification boxes checked, none left unchecked",
    "ready_to_merge_label" => "Label \"ready to merge\" applied"
  }.freeze

  # The criteria that need the PR description and labels. A session whose goal
  # names none of them has nothing for Github::GoalFactsEvaluator to record.
  PULL_REQUEST_FACT_CRITERIA = %w[verification_section verification_boxes_checked ready_to_merge_label].freeze

  # The criteria judged on a PR's own GitHub state, once there is a PR to read.
  # `pull_request_open` and `no_pull_request` are not among them: they judge
  # whether a PR was recorded at all, which is Zimmer's transcript heuristic, not
  # something GitHub shows.
  PER_PULL_REQUEST_CRITERIA = %w[ci_green verification_section verification_boxes_checked ready_to_merge_label].freeze

  READY_TO_MERGE_LABEL = "ready to merge"

  # How many generations of spawned sessions a PR goal is read through. Three
  # covers the deepest chain the fleet builds (a backlog top-up spawns a router,
  # which spawns the implementer).
  DELEGATION_DEPTH = 3

  # The most sessions read under any one parent. Applied per parent, not per call,
  # so a fleet run with hundreds of children on the same page as a router cannot
  # crowd the router's one child out of a batch.
  DELEGATION_FAN_OUT = 200

  # The custom_metadata keys a descendant contributes: the keys a verdict is read
  # from, plus the poll stamp. Only these are read, so a child's comment cache and
  # transcript bookkeeping never leave the database.
  DELEGATED_METADATA_KEYS = (Session::GOAL_CHECK_INPUT_KEYS + %w[poller_last_polled_at]).freeze

  # A jsonb object holding just DELEGATED_METADATA_KEYS. Built from constants only.
  DELEGATED_METADATA_SQL = begin
    pairs = DELEGATED_METADATA_KEYS.map { |key| "'#{key}', custom_metadata->'#{key}'" }
    "jsonb_build_object(#{pairs.join(', ')})"
  end

  # Per-criterion statuses:
  #   met     — the recorded state satisfies it
  #   unmet   — the recorded state contradicts it
  #   pending — it is waiting on something that resolves by itself (CI running, a
  #             PR recorded but not read from GitHub yet)
  #   unknown — Zimmer has no reading that could decide it
  STATUSES = %w[met unmet pending unknown].freeze

  # What the check cannot see, said wherever the result is shown so a `met` is
  # never read as more than it is.
  NOT_CHECKED_NOTE = "Advisory only: nothing acts on this. It covers only what Zimmer records and " \
                     "reads from GitHub. Anything else the goal asks for, such as a review, a skill, " \
                     "or a screenshot, is still the agent's word."

  Criterion = Data.define(:key, :label, :status, :detail) do
    def to_h
      { key: key, label: label, status: status, detail: detail }
    end
  end

  # One spawned session's PR state, as .delegated_pull_requests reads it:
  # `pr_state` is the DELEGATED_METADATA_KEYS slice of its custom_metadata.
  Delegate = Data.define(:id, :pr_state)

  # verdict — "met" when every criterion is met, "unmet" when any is, "pending"
  #   otherwise (nothing contradicts the goal, but not everything is known yet)
  # provisional — the session has not come to rest (running, or waiting for its
  #   next turn), so an unmet criterion is work in progress rather than a claim of
  #   completion
  # observed_at — when the poll pass last read the PRs judged, or nil
  # delegated_session_ids — the spawned sessions whose PRs were judged, empty when
  #   the session's own PRs were
  Result = Data.define(:goal_id, :goal_name, :verdict, :criteria, :observed_at, :provisional, :delegated_session_ids) do
    def met_count
      criteria.count { |c| c.status == "met" }
    end

    def delegated?
      delegated_session_ids.any?
    end

    def to_h
      {
        goal_id: goal_id,
        goal_name: goal_name,
        verdict: verdict,
        provisional: provisional,
        observed_at: observed_at&.iso8601,
        delegated_session_ids: delegated_session_ids,
        criteria: criteria.map(&:to_h),
        note: NOT_CHECKED_NOTE
      }
    end
  end

  class << self
    # @param session [Session]
    # @param delegates [Array<Delegate>, nil] the session's descendants' PR state,
    #   when the caller already batch-loaded it (.delegated_pull_requests); nil
    #   reads it on demand, and only if the session needs it
    # @return [Result, nil] nil when the goal is free text, or a catalog goal that
    #   declares no checks — there is nothing to report, which is not "met"
    def for(session, delegates: nil)
      goal = GoalsConfig.resolve(session.goal)
      return nil if goal.nil? || goal.checks.empty?

      new(session, goal, delegates: delegates).result
    end

    # Whether the poll pass should record PR description facts for this session.
    def reads_pull_request_facts?(session)
      goal = GoalsConfig.resolve(session.goal)
      goal.present? && goal.checks.intersect?(PULL_REQUEST_FACT_CRITERIA)
    end

    # Whether a session's check would read its descendants' PRs: its goal asks for
    # a PR and it recorded none of its own. Lets a list caller batch-load only the
    # sessions that need it.
    def reads_delegated_pull_requests?(session)
      goal = GoalsConfig.resolve(session.goal)
      goal.present? && goal.checks.include?("pull_request_open") && Github::PrRef.for_session(session).empty?
    end

    # The PR state of every session spawned under each of `session_ids`, up to
    # DELEGATION_DEPTH generations, in one query per generation.
    #
    # @param session_ids [Array<Integer>]
    # @return [Hash{Integer => Array<Delegate>}] every id given is a key
    def delegated_pull_requests(session_ids)
      result = session_ids.to_h { |id| [ id, [] ] }
      # node id => every requested id it is being read for. A list, because one
      # requested session can itself sit under another requested session.
      frontier = session_ids.to_h { |id| [ id, [ id ] ] }

      DELEGATION_DEPTH.times do
        break if frontier.empty?

        next_frontier = Hash.new { |hash, key| hash[key] = [] }
        children_of(frontier.keys).each do |id, parent_id, metadata|
          metadata = JSON.parse(metadata) if metadata.is_a?(String)
          delegate = Delegate.new(id: id, pr_state: metadata || {})

          frontier.fetch(parent_id).each do |ancestor|
            next if result[ancestor].any? { |seen| seen.id == id }

            result[ancestor] << delegate
            next_frontier[id] |= [ ancestor ]
          end
        end
        frontier = next_frontier
      end

      result
    end

    private

    # [id, parent_session_id, pr_state] for up to DELEGATION_FAN_OUT sessions under
    # each parent, oldest first.
    def children_of(parent_ids)
      ranked = Session.where(parent_session_id: parent_ids)
        .select(:id, :parent_session_id,
                Arel.sql("#{DELEGATED_METADATA_SQL} AS pr_state"),
                Arel.sql("ROW_NUMBER() OVER (PARTITION BY parent_session_id ORDER BY id) AS fan_out_rank"))

      Session.unscoped.from(ranked, :children)
        .where("children.fan_out_rank <= ?", DELEGATION_FAN_OUT)
        .order("children.id")
        .pluck(Arel.sql("children.id"), Arel.sql("children.parent_session_id"), Arel.sql("children.pr_state"))
    end
  end

  def initialize(session, goal, delegates: nil)
    @session = session
    @goal = goal
    metadata = session.custom_metadata || {}
    @refs = Github::PrRef.for_session(session)
    @statuses = hash_at(metadata, "github_pull_request_statuses")
    @ci_statuses = hash_at(metadata, "github_pull_request_ci_statuses")
    @facts = hash_at(metadata, Github::GoalFactsEvaluator::METADATA_KEY)
    @polled_at = hash_at(metadata, "poller_last_polled_at")[Github::PrPollPass::POLL_BACKOFF_KEY]
    @delegated_by_url = {}

    read_delegated_pull_requests(delegates) if @refs.empty? && @goal.checks.include?("pull_request_open")
  end

  def result
    criteria = @goal.checks.map { |key| evaluate(key) }

    Result.new(
      goal_id: @goal.id,
      goal_name: @goal.name,
      verdict: verdict_for(criteria),
      criteria: criteria,
      observed_at: parse_time(@polled_at),
      provisional: @session.running? || @session.waiting?,
      delegated_session_ids: @delegated_by_url.values.uniq
    )
  end

  private

  # Judge the PRs this session's descendants recorded, as if they were its own.
  # Only the PR-positive criteria get here: `no_pull_request` keeps reading the
  # session's own record, because a read-only session whose child opened a PR has
  # still not opened one itself.
  def read_delegated_pull_requests(delegates)
    delegates = self.class.delegated_pull_requests([ @session.id ]).fetch(@session.id) if delegates.nil?
    return if delegates.empty?

    polled = []
    delegates.each do |delegate|
      metadata = delegate.pr_state || {}
      refs = Github::PrRef.for_custom_metadata(metadata)
      next if refs.empty?

      refs.each do |ref|
        next if @delegated_by_url.key?(ref.url)

        @delegated_by_url[ref.url] = delegate.id
        @refs << ref
      end
      @statuses = hash_at(metadata, "github_pull_request_statuses").merge(@statuses)
      @ci_statuses = hash_at(metadata, "github_pull_request_ci_statuses").merge(@ci_statuses)
      @facts = hash_at(metadata, Github::GoalFactsEvaluator::METADATA_KEY).merge(@facts)
      polled << hash_at(metadata, "poller_last_polled_at")[Github::PrPollPass::POLL_BACKOFF_KEY]
    end

    # The OLDEST reading among the PRs judged: the verdict is only as fresh as its
    # stalest input, so that is the honest "PRs last read".
    stamps = polled.filter_map { |value| parse_time(value) }
    @polled_at = stamps.min&.iso8601
  end

  def verdict_for(criteria)
    statuses = criteria.map(&:status)
    return "unmet" if statuses.include?("unmet")
    return "met" if statuses.all?("met")

    "pending"
  end

  def evaluate(key)
    status, detail = send(:"check_#{key}")
    Criterion.new(key: key, label: CRITERIA.fetch(key), status: status, detail: detail)
  end

  # --- criteria ----------------------------------------------------------------

  def check_no_pull_request
    own = Github::PrRef.for_session(@session)
    return [ "met", nil ] if own.empty?

    [ "unmet", "Opened #{own.map(&:to_s).join(', ')}" ]
  end

  def check_pull_request_open
    return [ "unmet", "No pull request is recorded for this session or any session it spawned" ] if @refs.empty?
    return [ "met", subjects.map { |ref| "#{ref} #{@statuses[ref.url]}#{via(ref)}" }.join(", ") ] if subjects.any?
    return [ "pending", "Recorded, not read from GitHub yet" ] if live_refs.any?

    [ "unmet", "Every recorded pull request was closed without merging" ]
  end

  def check_ci_green
    per_subject do |ref|
      next [ "met", nil ] if merged?(ref)

      case @ci_statuses[ref.url]
      when "pass" then [ "met", nil ]
      when "fail" then [ "unmet", "failing" ]
      when "cancel" then [ "unmet", "cancelled" ]
      when "pending" then [ "pending", "running" ]
      when "skipping" then [ "unknown", "every check skipped" ]
      else [ "unknown", "no CI reading (no checks configured, or not read yet)" ]
      end
    end
  end

  def check_verification_section
    per_subject do |ref|
      facts = @facts[ref.url]
      next [ "unknown", "description not read yet" ] unless facts.is_a?(Hash)

      facts["verification_section"] ? [ "met", nil ] : [ "unmet", "no Verification heading" ]
    end
  end

  def check_verification_boxes_checked
    per_subject do |ref|
      facts = @facts[ref.url]
      next [ "unknown", "description not read yet" ] unless facts.is_a?(Hash)

      unchecked = facts["unchecked_boxes"].to_i
      if unchecked.positive?
        [ "unmet", "#{unchecked} unchecked #{unchecked == 1 ? 'box' : 'boxes'}" ]
      elsif facts["verification_checked_boxes"].to_i.zero?
        [ "unmet", "no checked box under Verification" ]
      else
        [ "met", nil ]
      end
    end
  end

  def check_ready_to_merge_label
    per_subject do |ref|
      next [ "met", nil ] if merged?(ref)

      facts = @facts[ref.url]
      next [ "unknown", "labels not read yet" ] unless facts.is_a?(Hash)

      labels = Array(facts["labels"])
      if labels.any? { |label| label.to_s.casecmp?(READY_TO_MERGE_LABEL) }
        [ "met", nil ]
      else
        [ "unmet", "label not applied" ]
      end
    end
  end

  # --- helpers -----------------------------------------------------------------

  # Recorded PRs that have not been closed without merging. A closed PR is work
  # the session abandoned or replaced, so it neither satisfies a PR goal nor
  # counts against one.
  def live_refs
    @live_refs ||= @refs.reject { |ref| @statuses[ref.url] == "closed" }
  end

  # Live PRs GitHub has actually been read for. These are what the per-PR
  # criteria judge; every one of them has to pass.
  def subjects
    @subjects ||= live_refs.select { |ref| %w[open merged].include?(@statuses[ref.url]) }
  end

  def merged?(ref)
    @statuses[ref.url] == "merged"
  end

  def via(ref)
    delegate_id = @delegated_by_url[ref.url]
    delegate_id ? " (via session ##{delegate_id})" : ""
  end

  # Evaluate a per-PR criterion across every subject PR and fold the answers:
  # one unmet PR makes the criterion unmet, and so on down STATUSES' severity.
  def per_subject
    return [ "unknown", "No pull request to read" ] if subjects.empty?

    answers = subjects.map { |ref| [ ref, *yield(ref) ] }
    status = %w[unmet pending unknown met].find { |s| answers.any? { |_, answer, _| answer == s } }

    notes = answers.filter_map do |ref, answer, note|
      next if answer == "met" || note.blank?

      subjects.size > 1 ? "#{ref}: #{note}" : note
    end

    [ status, notes.join("; ").presence ]
  end

  def hash_at(metadata, key)
    value = metadata[key]
    value.is_a?(Hash) ? value : {}
  end

  def parse_time(value)
    Time.zone.parse(value.to_s) if value.present?
  rescue ArgumentError
    nil
  end
end
