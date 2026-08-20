# frozen_string_literal: true

module OutcomeAnalyses
  # Lays a Segment tree out as a flamegraph (icicle): one row per depth, each
  # Segment a cell whose width is its share of its parent's width.
  #
  # The layout is computed once, server-side, into flat absolutely-positioned
  # cells. Nesting the DOM to mirror the tree would make a depth-8 analysis eight
  # levels of relatively-positioned divs and put a layout pass on every hover; a
  # flat list of `left`/`width` percentages renders the same picture and stays
  # cheap at hundreds of segments.
  #
  # Width is subtree SIZE (segment count), not wall-clock. A transcript segment's
  # duration is optional in the schema and frequently null, and the question this
  # view answers is "where did the work go and what failed", not "where did the
  # time go".
  class Flamegraph
    # Below this a cell is a sliver with no room for a label — it still renders
    # (it is still hoverable, and its color still counts toward the picture), it
    # just does not try to draw text into two pixels.
    LABEL_MIN_WIDTH_PERCENT = 4.0

    ROW_HEIGHT_PX = 22

    Cell = Data.define(
      :id, :depth, :left, :width, :outcome, :goal_text, :goal_kind,
      :trigger_kind, :trigger_source, :explanation, :subtree_size, :leaf, :model
    ) do
      def failure? = outcome == SegmentTree::FAILURE
      def labeled? = width >= LABEL_MIN_WIDTH_PERCENT
    end

    attr_reader :cells, :depth

    def initialize(root)
      @cells = []
      @depth = 0
      layout(root, 0, 0.0, 100.0) if root.is_a?(Hash)
      @cells.freeze
    end

    def height_px = (@depth + 1) * ROW_HEIGHT_PX

    def any? = @cells.any?

    private

    def layout(node, level, left, width)
      @depth = level if level > @depth

      children = Array(node["children"]).select { |child| child.is_a?(Hash) }
      @cells << build_cell(node, level, left, width, children.empty?)

      return if children.empty?

      # A parent is exactly as wide as its children plus itself, so children
      # partition the parent's width by subtree size. The parent's own "1" is not
      # given a slice — it is the row above, which is what makes the picture read
      # as containment rather than as a stacked bar.
      sizes = children.map { |child| subtree_size(child) }
      total = sizes.sum
      return if total.zero?

      offset = left
      children.each_with_index do |child, index|
        child_width = width * (sizes[index].to_f / total)
        layout(child, level + 1, offset, child_width)
        offset += child_width
      end
    end

    def build_cell(node, level, left, width, leaf)
      Cell.new(
        id: node["id"].to_s,
        depth: level,
        left: left.round(4),
        width: width.round(4),
        outcome: node.dig("outcome", "kind"),
        explanation: node.dig("outcome", "explanation").to_s,
        goal_text: node.dig("goal", "text").to_s,
        goal_kind: node.dig("goal", "kind"),
        trigger_kind: node.dig("trigger", "kind"),
        trigger_source: node.dig("trigger", "source"),
        subtree_size: subtree_size(node),
        leaf: leaf,
        model: node.dig("meta", "model")
      )
    end

    # Memoized on the node's object identity: a wide tree asks for the same
    # subtree's size once per sibling otherwise, which is quadratic on the way
    # down.
    def subtree_size(node)
      @sizes ||= {}
      @sizes[node.object_id] ||= 1 + Array(node["children"]).sum { |child| child.is_a?(Hash) ? subtree_size(child) : 0 }
    end
  end
end
