# frozen_string_literal: true

module OutcomeAnalyses
  # Validation and summarization of a Transcript Segment tree.
  #
  # A Segment is a `Trigger → Goal → Outcome` triplet, recursively nested; the
  # whole transcript is the root Segment. Zimmer never produces one of these —
  # an analysis session does, and hands it over through `save_outcome_analysis`
  # or POST /api/v1/outcome_analyses. So this class is the boundary: a tree that
  # gets past it is well-formed, and one that does not is rejected with the
  # reason rather than stored half-understood.
  #
  # Two deliberate deviations from the upstream agent-transcript-analysis spec:
  #
  #   * `outcome.explanation` is required and non-empty on Success as well as
  #     Failure. It is what the ledger's hover tooltips render, so a Success with
  #     nothing to say would leave a blank tooltip on most of the flamegraph.
  #     It is capped short for the same reason — a tooltip is not a paragraph.
  #   * The phase-3 analyzer fields (skill/MCP recommendations, efficiency) are
  #     not part of this schema at all. An unknown key is ignored, not stored.
  #
  # Outcome is LOCAL TO THE GOAL: a Failure Segment under a Success parent is the
  # normal, interesting case, not a contradiction to reject. Nothing here
  # propagates an outcome up or down the tree.
  class SegmentTree
    class InvalidTree < StandardError
      attr_reader :errors

      def initialize(errors)
        @errors = Array(errors)
        super(@errors.join("; "))
      end
    end

    ROOT_ID = "S0"
    TRIGGER_KINDS = %w[New Correction].freeze
    TRIGGER_SOURCES = %w[user agent subagent].freeze
    GOAL_KINDS = %w[Plan Action].freeze
    OUTCOME_KINDS = %w[Success Failure].freeze

    SUCCESS = "Success"
    FAILURE = "Failure"

    # Short enough to read as a tooltip without wrapping into a wall of text.
    EXPLANATION_MAX = 140
    GOAL_TEXT_MAX = 500
    # meta is free-form provenance rather than prose, but "free-form" still has to
    # mean bounded: without a cap here the node-count ceiling below bounds how
    # many segments a payload has and not how many bytes, and a 5,000-segment
    # tree carrying 100 KB per `meta.model` is a valid tree and a 500 MB page.
    META_STRING_MAX = 200
    NOTES_MAX = 1_000

    # Structural ceilings. Not a judgement about how deep a real analysis goes —
    # a backstop so a malformed or adversarial payload cannot make the renderer
    # (or the recursion below) the deployment's problem.
    MAX_SEGMENTS = 5_000
    MAX_DEPTH = 32
    # A tree that is wrong in ten thousand places is wrong; the caller needs
    # enough to fix it, not all of it. The MCP tool hands this list straight back
    # to the model that produced the tree, so an uncapped list is a megabyte of
    # someone's context.
    MAX_REPORTED_ERRORS = 50

    # Aggregate counts the ledger and the stats view read instead of the tree.
    Summary = Data.define(:segment_count, :failure_segment_count, :max_depth, :root_outcome) do
      def success_segment_count = segment_count - failure_segment_count
    end

    # @param root [Hash] the root Segment, string- or symbol-keyed
    # @return [Hash] the normalized tree (string keys, unknown keys dropped)
    # @raise [InvalidTree] with every problem found, not just the first
    def self.normalize!(root)
      new(root).normalize!
    end

    # @return [Summary]
    def self.summarize(root)
      counts = { total: 0, failures: 0, depth: 0 }
      walk(root, 1, counts)
      Summary.new(
        segment_count: counts[:total],
        failure_segment_count: counts[:failures],
        max_depth: counts[:depth],
        root_outcome: root.is_a?(Hash) ? root.dig("outcome", "kind") : nil
      )
    end

    # Depth-first, the same order the ids encode, so a caller can zip a flattened
    # list against the tree without re-deriving positions.
    def self.each_segment(root, depth = 0, &block)
      return unless root.is_a?(Hash)

      block.call(root, depth)
      Array(root["children"]).each { |child| each_segment(child, depth + 1, &block) }
    end

    def self.walk(node, depth, counts)
      return unless node.is_a?(Hash)

      counts[:total] += 1
      counts[:failures] += 1 if node.dig("outcome", "kind") == FAILURE
      counts[:depth] = depth if depth > counts[:depth]
      Array(node["children"]).each { |child| walk(child, depth + 1, counts) }
    end
    private_class_method :walk

    def initialize(root)
      @root = root
      @errors = []
    end

    def normalize!
      unless @root.is_a?(Hash)
        raise InvalidTree, "root must be a Segment object"
      end

      normalized = visit(@root.deep_stringify_keys, ROOT_ID, 1, 0)
      raise InvalidTree, reported_errors if @errors.any?

      normalized
    end

    private

    # @param expected_id [String] the id this node must carry, derived from its
    #   position. The ids are depth-first positional and deterministic, so the
    #   analyzer does not get to choose them — checking rather than trusting is
    #   what makes them safe to use as DOM ids and cross-references.
    def visit(node, expected_id, depth, index_in_parent)
      unless node.is_a?(Hash)
        error(expected_id, "must be a Segment object")
        return nil
      end

      if depth > MAX_DEPTH
        error(expected_id, "exceeds the maximum nesting depth of #{MAX_DEPTH}")
        return nil
      end

      @count = (@count || 0) + 1
      if @count > MAX_SEGMENTS
        error(expected_id, "tree exceeds the maximum of #{MAX_SEGMENTS} segments")
        return nil
      end

      id = node["id"].to_s
      error(expected_id, "has id #{id.inspect}, but its depth-first position makes it #{expected_id.inspect}") if id != expected_id

      children = node["children"]
      children = [] if children.nil?
      unless children.is_a?(Array)
        error(expected_id, "children must be an array")
        children = []
      end

      normalized_children = children.each_with_index.map do |child, i|
        visit(child, "#{expected_id}.#{i}", depth + 1, i)
      end.compact

      {
        "id" => expected_id,
        "trigger" => trigger(node["trigger"], expected_id, index_in_parent),
        "goal" => goal(node["goal"], expected_id),
        "outcome" => outcome(node["outcome"], expected_id),
        "meta" => meta(node["meta"], expected_id),
        "children" => normalized_children
      }
    end

    def trigger(value, id, index_in_parent)
      value = {} unless value.is_a?(Hash)
      kind = enum(value["kind"], TRIGGER_KINDS, id, "trigger.kind")
      source = enum(value["source"], TRIGGER_SOURCES, id, "trigger.source")

      # A Correction says "the previous sibling failed to deliver its own goal",
      # which the first child of a parent has no sibling to be about.
      if kind == "Correction" && index_in_parent.zero?
        error(id, "has a Correction trigger but no prior sibling to correct")
      end

      { "kind" => kind, "source" => source }
    end

    def goal(value, id)
      value = {} unless value.is_a?(Hash)
      text = value["text"].to_s.strip
      error(id, "goal.text is required") if text.empty?
      if text.length > GOAL_TEXT_MAX
        error(id, "goal.text is #{text.length} characters (max #{GOAL_TEXT_MAX})")
      end

      { "text" => text, "kind" => enum(value["kind"], GOAL_KINDS, id, "goal.kind") }
    end

    def outcome(value, id)
      value = {} unless value.is_a?(Hash)
      explanation = value["explanation"].to_s.strip
      error(id, "outcome.explanation is required (on Success as well as Failure)") if explanation.empty?
      if explanation.length > EXPLANATION_MAX
        error(id, "outcome.explanation is #{explanation.length} characters (max #{EXPLANATION_MAX}) — it renders as a hover tooltip, so keep it to one line")
      end

      { "kind" => enum(value["kind"], OUTCOME_KINDS, id, "outcome.kind"), "explanation" => explanation }
    end

    # Every meta field is optional and every one is nullable — an analyzer that
    # cannot recover token counts for a segment says so with null rather than
    # inventing a number.
    def meta(value, id)
      value = {} unless value.is_a?(Hash)

      range = value["event_range"]
      if range.is_a?(Array) && range.length == 2
        range = range.map { |bound| meta_string(bound) }
      elsif range.nil?
        range = nil
      else
        error(id, "meta.event_range must be a [start, end] pair or null")
        range = nil
      end

      {
        "event_range" => range,
        "wall_clock_s" => number_or_nil(value["wall_clock_s"]),
        "tokens_in" => integer_or_nil(value["tokens_in"]),
        "tokens_out" => integer_or_nil(value["tokens_out"]),
        "model" => meta_string(value["model"])
      }
    end

    # meta strings are event ids and model names — scalars, and short ones. A
    # non-scalar is dropped rather than stringified, so a Hash does not get
    # stored as its Ruby `inspect` output.
    def meta_string(value)
      return nil unless value.is_a?(String) || value.is_a?(Symbol) || value.is_a?(Numeric)

      value.to_s.strip.presence&.slice(0, META_STRING_MAX)
    end

    def enum(value, allowed, id, field)
      string = value.to_s
      return string if allowed.include?(string)

      error(id, "#{field} must be one of #{allowed.join(', ')} (got #{value.inspect})")
      allowed.first
    end

    def number_or_nil(value)
      return nil if value.nil? || value == ""
      Float(value)
    rescue ArgumentError, TypeError
      nil
    end

    def integer_or_nil(value)
      return nil if value.nil? || value == ""
      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end

    def error(id, message)
      @errors << "Segment #{id}: #{message}"
    end

    def reported_errors
      return @errors if @errors.size <= MAX_REPORTED_ERRORS

      @errors.first(MAX_REPORTED_ERRORS) + [ "(and #{@errors.size - MAX_REPORTED_ERRORS} more problems)" ]
    end
  end
end
