# frozen_string_literal: true

module Issues
  # Is this issue CONVERGENT (it closes a gap the fleet already knows about) or
  # DIVERGENT (it opens new surface area)? Resolved from three sources, in order,
  # because the three are landing at different times and none of them is complete
  # on its own.
  #
  #   1. The GitHub label — `convergent` / `divergent`. GitHub is the source of
  #      truth, and the issue gate is being changed to apply the label on every
  #      rating, so this is where the answer will live. It is NOT where the answer
  #      lives yet: the back-fill is in flight, and at the time of writing
  #      tadasant/zimmer carried the labels on none of its 208 open issues while
  #      tadasant/strad carried them on 53 of 55. Label absence is normal.
  #   2. The work backlog row's `scope_direction`, for an issue that is queued
  #      (or was). Written by the gate when it appended the item.
  #   3. The most recent `issue_work` GateDecision for the issue's URL. Every
  #      rating the gate has ever made is in that ledger, including ones for
  #      issues that never reached the queue.
  #   4. Otherwise UNRATED, said out loud rather than guessed. "We have not rated
  #      this yet" is a useful thing for the page to show — it is the pile of work
  #      the gate has not seen.
  #
  # The resolver is built once per request from two bulk reads, so resolving 900
  # issues costs two queries rather than 1800.
  class Direction
    CONVERGENT = "convergent"
    DIVERGENT = "divergent"
    UNRATED = "unrated"

    # The values a direction can take on the page, in the order they are shown.
    ALL = [ CONVERGENT, DIVERGENT, UNRATED ].freeze

    # The two that are also GitHub label names, spelled exactly as the labels are.
    LABELS = [ CONVERGENT, DIVERGENT ].freeze

    # Which of the four rules answered. Rendered as a tooltip on the pill, so a
    # reader can tell "GitHub says convergent" from "we inferred it from a rating
    # in July".
    SOURCES = { label: "the GitHub label", backlog: "the backlog row", gate: "the issue gate's rating",
                none: "not rated yet" }.freeze

    Resolution = Data.define(:direction, :source) do
      def rated? = direction != Issues::Direction::UNRATED
      def source_label = Issues::Direction::SOURCES.fetch(source, "unknown")
    end

    UNRESOLVED = Resolution.new(direction: UNRATED, source: :none)

    # @param issue_urls [Array<String>] every issue URL the page will ask about.
    #   Used to bound the GateDecision read — the ledger holds thousands of rows
    #   whose payloads average 11.5 KB, so it is read as two columns and not as
    #   models.
    def initialize(issue_urls: [])
      urls = Array(issue_urls).compact.uniq
      @backlog = backlog_directions(urls)
      @gate = gate_directions(urls)
    end

    # @param labels [Array<String>] the issue's current GitHub labels
    # @param issue_url [String, nil]
    # @return [Resolution]
    def call(labels: [], issue_url: nil)
      labelled = Array(labels).find { |name| LABELS.include?(name) }
      return Resolution.new(direction: labelled, source: :label) if labelled

      url = issue_url.presence
      return UNRESOLVED if url.nil?

      from_backlog = @backlog[url]
      return Resolution.new(direction: from_backlog, source: :backlog) if from_backlog

      from_gate = @gate[url]
      return Resolution.new(direction: from_gate, source: :gate) if from_gate

      UNRESOLVED
    end

    # The direction of a queued item, which always has a `scope_direction` column
    # — but whose GitHub label, once the back-fill reaches it, still wins.
    def for_item(item, github_issue = nil)
      labelled = github_issue && Array(github_issue.labels).find { |name| LABELS.include?(name) }
      return Resolution.new(direction: labelled, source: :label) if labelled
      return Resolution.new(direction: item.scope_direction, source: :backlog) if item.scope_direction.present?

      call(issue_url: item.issue_url)
    end

    private

    # The queued row wins over a started/removed one for the same issue — the
    # queue is the live reading — so queued rows are loaded last and overwrite.
    def backlog_directions(urls)
      return {} if urls.empty?

      WorkBacklogItem.where(issue_url: urls)
                     .order(Arel.sql("status = 'queued'"), :id)
                     .pluck(:issue_url, :scope_direction)
                     .to_h
    end

    # Two columns, never whole rows: an issue_work payload averages 11.5 KB and
    # this page can ask about 900 URLs at once. Ordered oldest-first so `to_h`
    # leaves the most recent rating in place — the ledger is append-only, and a
    # re-rate is a new row rather than an edit.
    def gate_directions(urls)
      return {} if urls.empty?

      GateDecision.for_gate(GateDecision::ISSUE_WORK)
                  .where(artifact_url: urls)
                  .order(:decided_at, :id)
                  .pluck(:artifact_url, Arel.sql("COALESCE(payload->>'scope_direction', payload->'ratings'->>'scope_direction')"))
                  .to_h
                  .compact
                  .select { |_url, value| LABELS.include?(value) }
    end
  end
end
