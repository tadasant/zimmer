# frozen_string_literal: true

module Github
  # Records what a PR goal asks the pull request itself to carry — a Verification
  # section, its boxes checked, the `ready to merge` label — so GoalCheck can read
  # it back without a GitHub call of its own.
  #
  # Driven by Github::PrPollPass, off the same `gh pr view` reading the other
  # evaluators take: it adds `body,labels` to Github::PrSnapshot::JSON_FIELDS and
  # no round trip. Only sessions whose goal names one of
  # GoalCheck::PULL_REQUEST_FACT_CRITERIA get facts recorded; nothing else reads them.
  #
  # Stores derived facts, not the body. A PR description can run to tens of
  # kilobytes and every session page broadcast carries custom_metadata, so the
  # description is reduced to the four values the criteria need:
  #
  #   { "https://github.com/o/r/pull/1" => {
  #       "verification_section" => true,
  #       "verification_checked_boxes" => 4,
  #       "unchecked_boxes" => 0,
  #       "labels" => ["ready to merge"] } }
  #
  # A PR this pass could not read keeps whatever was recorded for it. A missed
  # reading is "we did not learn anything", never "the description is empty".
  class GoalFactsEvaluator
    include DatabaseRetry

    METADATA_KEY = "github_pull_request_goal_facts"

    # An ATX heading (one to six #s) whose first word is "Verification". Leading
    # punctuation or an emoji is allowed ("## ✅ Verification").
    VERIFICATION_HEADING = /\A {0,3}\#{1,6}\s+[^\p{L}\p{N}]*verification\b/i
    ANY_HEADING = /\A {0,3}(\#{1,6})\s+\S/
    # A task-list item: a bullet or an ordered-list marker, then [ ], [x] or [X].
    # GitHub renders one inside a blockquote as a checkbox too, so `>` may lead.
    TASK_ITEM = /\A\s*(?:>\s*)*(?:[-*+]|\d+[.)])\s+\[([ xX])\]/
    # A code fence. A fence closes only on a run of the same character at least as
    # long as the one that opened it, so a ```` block can quote a ``` one.
    FENCE = /\A {0,3}(`{3,}|~{3,})/
    # A closed comment, or one left open — GitHub hides everything after an
    # unterminated `<!--`.
    HTML_COMMENT = /<!--.*?(?:-->|\z)/m

    # @param session [Session]
    # @param refs [Array<Github::PrRef>]
    # @param snapshots [Hash{String => Github::PrSnapshot, nil}]
    # @return [void]
    def evaluate(session, refs, snapshots)
      return if refs.empty?
      return unless GoalCheck.reads_pull_request_facts?(session)

      current = session.custom_metadata&.dig(METADATA_KEY)
      current = {} unless current.is_a?(Hash)
      updated = current.dup

      refs.each do |ref|
        snapshot = snapshots[ref.url]
        next if snapshot.nil? || snapshot.body.nil?

        updated[ref.url] = self.class.facts_for(snapshot)
      end

      return if updated == current

      # Merged in Postgres, for the reason Github::PrStatusEvaluator gives: the row
      # this pass read is seconds stale by now.
      with_db_retry { session.merge_custom_metadata!(METADATA_KEY => updated) }
    end

    # @param snapshot [Github::PrSnapshot]
    # @return [Hash{String => Object}]
    def self.facts_for(snapshot)
      facts = body_facts(snapshot.body.to_s)
      facts["labels"] = Array(snapshot.labels).map(&:to_s)
      facts
    end

    # Read the description the way a person reading the rendered PR would: text in
    # a fenced code block or an HTML comment is not shown, so a template's
    # commented-out checklist and an example quoted in a code block count for
    # nothing.
    #
    # @param body [String]
    # @return [Hash{String => Object}]
    def self.body_facts(body)
      verification_section = false
      verification_level = nil
      verification_checked = 0
      unchecked = 0
      open_fence = nil

      body.gsub(HTML_COMMENT, "").each_line do |line|
        if (fence = line.match(FENCE))
          marker = fence[1]
          if open_fence.nil?
            open_fence = marker
          elsif marker[0] == open_fence[0] && marker.length >= open_fence.length
            open_fence = nil
          end
          next
        end
        next if open_fence

        if (heading = line.match(ANY_HEADING))
          level = heading[1].length
          if line.match?(VERIFICATION_HEADING)
            verification_section = true
            verification_level = level
          elsif verification_level && level <= verification_level
            # A sibling or parent heading ends the Verification section.
            verification_level = nil
          end
          next
        end

        next unless (item = line.match(TASK_ITEM))

        if item[1] == " "
          unchecked += 1
        elsif verification_level
          verification_checked += 1
        end
      end

      {
        "verification_section" => verification_section,
        "verification_checked_boxes" => verification_checked,
        "unchecked_boxes" => unchecked
      }
    end
  end
end
