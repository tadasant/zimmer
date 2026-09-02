# frozen_string_literal: true

module GateDecisions
  # Turns one raw ledger entry — the JSON object a gate appends, or the argument
  # hash an MCP/REST caller sends — into the columns GateDecision promotes plus
  # the payload it keeps verbatim.
  #
  # WHAT IT PROMOTES, AND WHY SO LITTLE
  #
  # The two gates do not share a schema and neither gate's schema is finished. On
  # 300 PR-gate zimmer entries there are 34 distinct keys, 11 of them universal;
  # four (`hold_tests`, `ci`, `verification_note`, `disclosures`) appear only on
  # the most recent 52, and four more (`diff`, `s1`, `hold_list`, `sanity_check`)
  # are retired. So this promotes only what both gates have always had and what a
  # query actually filters on, and leaves the rest alone.
  #
  # WHAT IT REFUSES TO CARRY
  #
  # `human_feedback` is stripped, always, on every path. It is not a payload key
  # in this schema — it is GateDecisionFeedback, written from a human boundary
  # only. Leaving it in `payload` would hand back exactly the forgery this design
  # exists to prevent: a machine writing a note that says a human said something.
  class Entry
    # The key holding the rated artifact's URL, per gate. The PR gate also has an
    # `issue` key, but it is long-form prose about the issue the PR closes — the
    # artifact this row is a rating OF is the pull request.
    ARTIFACT_KEY = {
      GateDecision::PR_MERGE => "pr",
      GateDecision::ISSUE_WORK => "issue"
    }.freeze

    # Where the session that produced the rated work is named. Free text in both
    # gates: usually a URL, often a URL followed by a paragraph, sometimes absent.
    SESSION_KEYS = %w[producing_session spawned_session].freeze

    FORBIDDEN_KEYS = %w[human_feedback].freeze

    URL_PATTERN = %r{https?://[^\s<>"'\\]+}

    # A promoted value that overruns its column would fail validation and, in the
    # importer, take the whole batch with it. These are guards on a value pulled
    # out of free-form prose, not limits anyone should reach: the longest URL in
    # the historical corpus is 69 characters and the longest decision is 43.
    MAX_URL = GateDecision::MAX_URL_LENGTH
    MAX_DECISION = 200

    attr_reader :gate, :surface, :raw

    # @param gate [String] "pr_merge" or "issue_work"
    # @param surface [String] the agent root / repo the gate rated on
    # @param raw [Hash] the entry as written
    def initialize(gate:, surface:, raw:)
      @gate = gate
      @surface = surface
      @raw = raw.is_a?(Hash) ? raw.deep_stringify_keys : {}
    end

    def attributes
      {
        gate: gate,
        surface: surface,
        artifact_url: artifact_url,
        decided_at: decided_at,
        decision: decision,
        producing_session_url: producing_session_url,
        payload: payload
      }
    end

    # Everything the entry carried, minus the keys this schema refuses to store
    # in a machine-writable column. The promoted values above are copies, not
    # moves: a reader that only knows the JSON schema still sees whole entries.
    def payload
      scrub(raw)
    end

    # The `human_feedback` array as the source wrote it, for the importer to turn
    # into GateDecisionFeedback rows. Never reachable from a live write path — the
    # MCP tool and the REST create action both drop it on the floor.
    #
    # Exact key, exact casing, top level only — deliberately narrower than `scrub`
    # below. The two are asymmetric on purpose: the scrub is defensive and removes
    # anything that *looks* like feedback, while this promotes source data into the
    # one table a machine cannot write, so it recognizes only the shape the gates
    # actually wrote. Every one of the 8 notes in the historical corpus has it.
    def human_feedback
      Array(raw["human_feedback"]).select { |item| item.is_a?(Hash) }
    end

    def artifact_url
      first_url(raw[ARTIFACT_KEY.fetch(gate, "pr")])
    end

    def producing_session_url
      SESSION_KEYS.lazy.filter_map { |key| first_url(raw[key]) }.first
    end

    def decision
      value = raw["decision"]
      text = value.is_a?(String) ? value.strip : value.presence&.to_s
      text.presence&.truncate(MAX_DECISION)
    end

    # The gates write a plain `"2026-09-02"`. Anything else — a bare year, a null,
    # a sentence — yields nil rather than a wrong date: an unparseable value is a
    # fact about the entry, and inventing 1 January for it would put the row in the
    # wrong place in every recency query that follows.
    def decided_at
      value = raw["decided_at"]
      return value if value.is_a?(Date)
      return nil unless value.is_a?(String)

      Date.iso8601(value.strip)
    rescue ArgumentError, TypeError
      nil
    end

    private

    # A URL out of a value that is sometimes a URL and sometimes a paragraph that
    # opens with one. Trailing sentence punctuation is trimmed, because
    # "https://…/sessions/684. The recurring…" is a real shape in this corpus and
    # the period is not part of the link.
    def first_url(value)
      return nil unless value.is_a?(String)

      match = value[URL_PATTERN]
      return nil unless match

      match.sub(/[.,;:)\]]+\z/, "").presence&.truncate(MAX_URL)
    end

    # Every forbidden key, at every depth, whatever its casing. Values are walked
    # rather than only the top level — see the class comment.
    def scrub(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, nested), kept|
          next if FORBIDDEN_KEYS.include?(key.to_s.downcase)

          kept[key] = scrub(nested)
        end
      when Array then value.map { |item| scrub(item) }
      else value
      end
    end
  end
end
