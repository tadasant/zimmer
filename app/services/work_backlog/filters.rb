# frozen_string_literal: true

module WorkBacklog
  # The filter set the REST index and the `get_work_backlog` MCP tool share, so
  # the two surfaces cannot answer "what is on the queue" differently.
  #
  # Built from a plain string-keyed Hash — `params` from a controller, `args`
  # from a tool. Validates rather than silently ignoring: a groomer that filters
  # on `estimated_cost: "S"` should be told, not handed an empty queue it reads
  # as "nothing to pull".
  class Filters
    class InvalidFilter < StandardError; end

    DEFAULT_LIMIT = 50
    MAX_LIMIT = 200
    ANY_STATUS = "all"

    KEYS = %w[status surface repo scope_direction kind estimated_cost pinned key added_by].freeze

    # ActiveModel's Boolean cast reads any non-blank string that is not a known
    # false word as true ("maybe" => true), which is the wrong answer for a flag
    # that decides whether a human hand-placed an item. This is the strict read.
    TRUE_WORDS = %w[true t 1 yes y on].freeze
    FALSE_WORDS = %w[false f 0 no n off].freeze

    # @return [true, false, nil, :invalid] nil for absent/blank, :invalid for
    #   anything that is not clearly one or the other
    def self.strict_bool(value)
      return value if value == true || value == false
      return nil if value.nil?

      word = value.to_s.strip.downcase
      return nil if word.empty?
      return true if TRUE_WORDS.include?(word)
      return false if FALSE_WORDS.include?(word)

      :invalid
    end

    attr_reader :status, :surface, :repo, :scope_direction, :kind, :estimated_cost, :pinned, :key,
                :added_by, :limit, :offset

    def initialize(source)
      source = source.to_h.deep_stringify_keys

      @status = parse_status(source["status"])
      @surface = source["surface"].presence&.to_s&.strip
      @repo = source["repo"].presence&.to_s&.strip
      @scope_direction = parse_enum(source["scope_direction"], WorkBacklogItem::SCOPE_DIRECTIONS, "scope_direction")
      @kind = source["kind"].presence&.to_s&.strip
      @estimated_cost = parse_enum(source["estimated_cost"], WorkBacklogItem::COSTS, "estimated_cost")
      @pinned = parse_bool(source["pinned"])
      @key = source["key"].presence&.to_s&.strip
      @added_by = source["added_by"].presence&.to_s&.strip
      @limit = parse_int(source["limit"], "limit", default: DEFAULT_LIMIT, min: 1, max: MAX_LIMIT)
      @offset = parse_int(source["offset"], "offset", default: 0, min: 0)
    end

    # The filtered relation in rank order. Deliberately does NOT apply
    # `limit`/`offset` — the REST index paginates with its own helper, and the
    # MCP tool slices with these.
    def scope
      scope = WorkBacklogItem.all
      scope = scope.where(status: status) unless status == ANY_STATUS
      scope = scope.where(surface: surface) if surface
      scope = scope.where(repo: repo) if repo
      scope = scope.where(scope_direction: scope_direction) if scope_direction
      scope = scope.where(kind: kind) if kind
      scope = scope.where(estimated_cost: estimated_cost) if estimated_cost
      scope = scope.where(pinned: pinned) unless pinned.nil?
      scope = scope.where(key: key) if key
      scope = scope.where(added_by: added_by) if added_by
      scope.in_rank_order
    end

    def describe
      parts = [ "status=#{status}" ]
      parts << "surface=#{surface}" if surface
      parts << "repo=#{repo}" if repo
      parts << "scope_direction=#{scope_direction}" if scope_direction
      parts << "kind=#{kind}" if kind
      parts << "estimated_cost=#{estimated_cost}" if estimated_cost
      parts << "pinned=#{pinned}" unless pinned.nil?
      parts << "key=#{key}" if key
      parts << "added_by=#{added_by}" if added_by
      parts.join(", ")
    end

    private

    # The queue is what callers almost always mean, so `queued` is the default;
    # `all` widens to history.
    def parse_status(value)
      value = value.presence&.to_s&.strip
      return WorkBacklogItem::QUEUED if value.nil?
      return ANY_STATUS if value == ANY_STATUS
      return value if WorkBacklogItem::STATUSES.include?(value)

      raise InvalidFilter, "status must be one of #{(WorkBacklogItem::STATUSES + [ ANY_STATUS ]).join(', ')} (got #{value.inspect})"
    end

    def parse_enum(value, allowed, name)
      value = value.presence&.to_s&.strip
      return nil if value.nil?
      return value if allowed.include?(value)

      raise InvalidFilter, "#{name} must be one of #{allowed.join(', ')} (got #{value.inspect})"
    end

    def parse_bool(value)
      cast = self.class.strict_bool(value)
      raise InvalidFilter, "pinned must be true or false (got #{value.inspect})" if cast == :invalid

      cast
    end

    def parse_int(value, name, default:, min:, max: nil)
      return default if value.nil? || value.to_s.strip.empty?

      int = Integer(value)
      raise InvalidFilter, "#{name} must be at least #{min} (got #{int})" if int < min

      max ? [ int, max ].min : int
    rescue ArgumentError, TypeError
      raise InvalidFilter, "#{name} must be an integer (got #{value.inspect})"
    end
  end
end
