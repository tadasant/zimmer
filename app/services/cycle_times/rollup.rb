# frozen_string_literal: true

module CycleTimes
  # Folds a hierarchy's per-session lanes into one account of its wall-clock.
  #
  # Sessions in a hierarchy overlap — a router waits while three children work
  # in parallel — so "how long did the task spend on inference" has two honest
  # answers, and this produces both:
  #
  # * HIERARCHY TIME (the headline, `totals`): at every instant between the
  #   first session's creation and the last archive, ask what the task as a
  #   whole was doing, and charge that instant to exactly one category — the
  #   highest-priority category among the segments covering it
  #   (Categories::ALL's `priority`). Work beats waiting, so an instant where
  #   one child runs tests while another sleeps on CI is local I/O, not CI: the
  #   task was not blocked. Among waits the most specific wins, and a parent's
  #   wait on a child always loses to what that child is doing. An instant no
  #   lane covers is `unattributed`. These totals sum to the wall-clock exactly.
  #
  # * SESSION TIME (`summed_totals`): every lane's own totals added up. Larger
  #   than the wall-clock whenever sessions overlapped, and the right number for
  #   "how much inference did this task consume".
  #
  # `contributions` records how many seconds of hierarchy time each lane
  # segment won, which is what "the top contributing segments" means.
  class Rollup
    Result = Data.define(:totals, :summed_totals, :segments, :contributions)

    # @param lanes [Array<Array<LaneBuilder::Segment>>] one array per session, root first
    # @param start [Time] the hierarchy's first creation
    # @param finish [Time] its last archive
    def initialize(lanes, start:, finish:)
      @lanes = lanes
      @start = start
      @finish = [ finish, start ].max
    end

    # An event sweep: every segment opens at its start and closes at its finish,
    # and the active segments are kept per category, so each boundary costs one
    # pass over the category list rather than one over every lane. A
    # 300-session hierarchy with thousands of segments per lane stays linear in
    # its segment count.
    def call
      totals = Hash.new(0.0)
      contributions = Hash.new(0.0) # [lane, index] => seconds
      merged = []
      active = Hash.new { |h, k| h[k] = {} } # category => { [lane, index] => segment }

      events = Hash.new { |h, k| h[k] = [] }
      @lanes.each_with_index do |segments, lane|
        segments.each_with_index do |segment, index|
          from = segment.start.clamp(@start, @finish)
          to = segment.finish.clamp(@start, @finish)
          next unless to > from

          events[from] << [ :open, lane, index, segment ]
          events[to] << [ :close, lane, index, segment ]
        end
      end

      (events.keys + [ @start, @finish ]).uniq.sort.each_cons(2) do |t0, t1|
        events[t0].each do |kind, lane, index, segment|
          if kind == :open
            active[segment.category][[ lane, index ]] = segment
          else
            active[segment.category].delete([ lane, index ])
          end
        end

        seconds = t1 - t0
        category = active.keys.select { |key| active[key].any? }.max_by { |key| Categories.priority(key) }
        if category
          (lane, index), segment = active[category].min_by { |(l, i), _| [ l, i ] }
          totals[category] += seconds
          contributions[[ lane, index ]] += seconds
          append(merged, t0, t1, category, segment.detail, lane)
        else
          totals["unattributed"] += seconds
          append(merged, t0, t1, "unattributed", "no session in the hierarchy was alive", nil)
        end
      end

      summed = Hash.new(0.0)
      @lanes.flatten.each { |segment| summed[segment.category] += segment.seconds }

      Result.new(totals: totals, summed_totals: summed, segments: merged, contributions: contributions)
    end

    private

    # The hierarchy lane: what won each instant, with touching stretches of the
    # same category from the same lane merged.
    def append(merged, t0, t1, category, detail, lane)
      last = merged.last
      if last && last[:category] == category && last[:lane] == lane && last[:finish] == t0
        last[:finish] = t1
      else
        merged << { start: t0, finish: t1, category: category, detail: detail, lane: lane }
      end
    end
  end
end
