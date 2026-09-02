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
  # `fields` is everything, and it is the non-negotiable half: `glance` may pick,
  # the entry view never omits.
  #
  # ORDER IS POSTGRES'S, NOT THE GATE'S. `payload` is `jsonb`, which normalizes an
  # object on the way in: keys come back shortest-first, then bytewise, whatever
  # order the gate wrote them. That is stable and deterministic — the same entry
  # always renders the same way — but it is not authoring order, and nothing here
  # can recover authoring order because the column never stored it. Sorting the
  # keys some other way would only trade one arbitrary order for another, so this
  # takes the one the database gives and says so.
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

    # The most elements an array is drawn one-per-card. The longest list in the
    # corpus holds 5.
    MAX_ITEMS = 200

    # One renderable value: what to call it, what it is, and — for the two
    # container kinds — the fields inside it, already classified.
    Field = Struct.new(:key, :value, :kind, :children, :depth, :position, keyword_init: true) do
      # Keys are snake_case in both gates' schemas. Humanized for display, but
      # never rewritten: an unrecognized key still reads as itself.
      def label
        key.to_s.tr("_", " ").strip.presence&.upcase_first || key.to_s
      end

      # A jump-link target, and it has to be UNIQUE — a duplicate id sends every
      # link in "The reasoning" to whichever section came first.
      #
      # The key alone is not unique, and the payload is the one place we cannot
      # assume otherwise. `parameterize` maps "Reason" and "reason" together, and
      # "a_b" / "a-b" / "a b" together; a key with no ASCII letters at all — a
      # gate writing Japanese — slugifies to the empty string, so two of those
      # would both land on `entry-field`. So the field's position carries the
      # uniqueness and the slug carries the readability.
      def anchor
        slug = key.to_s.parameterize.tr("_", "-").gsub(/\A-+|-+\z/, "")
        "entry-#{position}-#{slug.presence || 'field'}"
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

    # Every top-level field, in the order `jsonb` gives them back — shortest key
    # first, then bytewise. Nothing is dropped.
    def fields
      @fields ||= build(payload, depth: 0, prefix: "")
    end

    def any?
      fields.any?
    end

    # The skimmable half — ratings, axes, flags, short verdict words.
    def glance
      @glance ||= fields.select { |field| field.skimmable? && !field.blank? }
    end

    # The long-form half, which is what someone auditing a hold came to read.
    # Doubles as the jump list on the detail page — and TOP-LEVEL is what makes
    # that work, not an oversight: the detail page gives a `<section>` (and so an
    # anchor) to each top-level field, so a nested prose field has no target a
    # jump link could point at. It is still rendered in full, inside its parent.
    def prose_fields
      @prose_fields ||= fields.select(&:prose?)
    end

    private

    def build(hash, depth:, prefix:)
      hash.each_with_index.map { |(key, value), index| field_for(key, value, depth, "#{prefix}#{index}") }
    end

    def field_for(key, value, depth, position)
      kind = classify(value, depth)
      children = case kind
      when :object then build(value, depth: depth + 1, prefix: "#{position}-")
      when :list
        value.each_with_index.map do |item, index|
          field_for("#{key} #{index + 1}", item, depth + 1, "#{position}-#{index}")
        end
      end

      Field.new(key: key, value: value, kind: kind, children: children, depth: depth, position: position)
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
      stripped = value.strip
      return :blank if stripped.empty?
      return :url if stripped.match?(%r{\Ahttps?://\S+\z})

      value.length > PROSE_LENGTH || value.include?("\n") ? :prose : :text
    end

    def classify_array(value, depth)
      return :blank if value.empty?
      return :json if depth >= MAX_DEPTH
      # The breadth counterpart to MAX_DEPTH, and it matters for the same reason:
      # a payload is allowed up to 512 KB, so an array far longer than anything a
      # gate writes today would otherwise become one Field struct and one partial
      # render per element. Past the cap it is still shown, as JSON.
      return :json if value.length > MAX_ITEMS
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
