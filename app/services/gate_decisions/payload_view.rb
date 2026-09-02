# frozen_string_literal: true

module GateDecisions
  # Turns one decision's `payload` into something a page can render WITHOUT
  # knowing what is in it.
  #
  # WHY THIS IS SHAPE-DRIVEN AND NOT KEY-DRIVEN
  #
  # There is no schema here to render against. Across 318 PR-gate zimmer entries
  # there are 34 distinct keys, 11 of them universal; four arrived in the last few
  # weeks and four are retired and appear only on early entries. A view built from
  # a list of field names would be wrong within a month, silently, by omission —
  # the gate would add `disclosures`, the page would keep looking complete, and
  # nobody auditing a hold would know a section was missing.
  #
  # So nothing here looks at a key name. Every value is classified by its SHAPE,
  # and the classification decides how it is drawn:
  #
  #   nil / "" / [] / {}   :blank    an em dash, so an absent field still shows
  #   true / false         :boolean  a yes/no pill
  #   3, 1.5               :number   a tabular figure
  #   "https://…"          :url      a link
  #   "hold"               :text     an inline value
  #   1,200 chars of prose :prose    a markdown block, the substance of the entry
  #   ["a", "b"]           :chips    a row of chips
  #   [{…}, {…}]           :list     one nested card per element
  #   {"a" => …}           :object   a nested definition list
  #   anything past MAX_DEPTH        pretty-printed JSON, rather than nothing
  #
  # The last line is the point of the depth cap: a shape this has never seen
  # degrades to legible JSON instead of an exception or a blank.
  #
  # WHAT IS SKIMMABLE
  #
  # `glance` is the answer to "what did this gate decide, at a glance" — the
  # ratings, the axes, the booleans, the short verdict words. That is also
  # derived from shape, not from names: a field is skimmable when it and
  # everything under it renders short. `ratings` and `justifications` are the
  # worked example — same keys, same nesting, but one holds four words and the
  # other four paragraphs, so one skims and the other does not, and no rule
  # naming either of them was needed to get that right.
  #
  # `fields` is everything, in the order the gate wrote it, and it is the
  # non-negotiable half: `glance` may pick, the entry view never omits.
  class PayloadView
    # Above this many characters, or across a line break, a string stops being a
    # value on a row and becomes a paragraph with its own heading. Tuned to the
    # corpus: the longest `decision` is 43 characters and the longest promoted
    # URL is 69, while the shortest `reason` runs to several hundred.
    PROSE_LENGTH = 120

    # How far the shape-driven renderer recurses before it hands the rest to a
    # JSON block. Deepest nesting in the corpus is 2 (`staleness_check.finding`),
    # so this is a guard against an entry shaped like nothing seen so far, not a
    # limit anyone should reach.
    MAX_DEPTH = 4

    # One renderable value: what to call it, what it is, and — for the two
    # container kinds — the fields inside it, already classified.
    Field = Struct.new(:key, :value, :kind, :children, :depth, keyword_init: true) do
      # Keys are snake_case in both gates' schemas. Humanized for display, but
      # never rewritten: an unrecognized key still reads as itself.
      def label
        key.to_s.tr("_", " ").strip.presence&.upcase_first || key.to_s
      end

      # Stable enough for a jump link, and prefixed so a payload key cannot
      # collide with an id elsewhere on the page. A key that slugifies to nothing
      # — punctuation only — still gets a usable anchor rather than `entry-`.
      def anchor
        slug = key.to_s.parameterize.tr("_", "-").gsub(/\A-+|-+\z/, "")
        "entry-#{slug.presence || 'field'}"
      end

      def prose? = kind == :prose
      def container? = %i[object list].include?(kind)
      def blank? = kind == :blank

      # Renders short, all the way down — so it can sit in the at-a-glance panel
      # without turning it into a second copy of the entry.
      def skimmable?
        return false if prose? || kind == :json
        return true unless container?

        children.all?(&:skimmable?)
      end
    end

    attr_reader :payload

    def initialize(payload)
      @payload = payload.is_a?(Hash) ? payload : {}
    end

    # Every top-level field, in the order the gate wrote it. Nothing is dropped.
    def fields
      @fields ||= build(payload, depth: 0)
    end

    def any?
      fields.any?
    end

    # The skimmable half — ratings, axes, flags, short verdict words.
    def glance
      @glance ||= fields.select { |field| field.skimmable? && !field.blank? }
    end

    # The long-form half, which is what someone auditing a hold came to read.
    # Doubles as the jump list on the detail page.
    def prose_fields
      @prose_fields ||= fields.select(&:prose?)
    end

    private

    def build(hash, depth:)
      hash.map { |key, value| field_for(key, value, depth) }
    end

    def field_for(key, value, depth)
      kind = classify(value, depth)
      children = case kind
      when :object then build(value, depth: depth + 1)
      when :list then value.each_with_index.map { |item, index| field_for("#{key} #{index + 1}", item, depth + 1) }
      end

      Field.new(key: key, value: value, kind: kind, children: children, depth: depth)
    end

    def classify(value, depth)
      case value
      when nil then :blank
      when true, false then :boolean
      when Numeric then :number
      when String then classify_string(value)
      when Array then classify_array(value, depth)
      when Hash then value.empty? ? :blank : (depth < MAX_DEPTH ? :object : :json)
      else :json
      end
    end

    def classify_string(value)
      return :blank if value.strip.empty?
      return :url if value.strip.match?(%r{\Ahttps?://\S+\z})

      value.length > PROSE_LENGTH || value.include?("\n") ? :prose : :text
    end

    def classify_array(value, depth)
      return :blank if value.empty?
      return :json if depth >= MAX_DEPTH
      # A list of short scalars is a row of chips; anything heavier gets a card
      # each. `facets: ["subtractive"]` and `disclosures: [{…}, {…}]` are both in
      # the corpus and neither needed a rule mentioning it.
      value.all? { |item| chip?(item) } ? :chips : :list
    end

    def chip?(item)
      case item
      when true, false, Numeric then true
      when String then item.length <= PROSE_LENGTH && !item.include?("\n")
      else false
      end
    end
  end
end
