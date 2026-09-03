# frozen_string_literal: true

module Issues
  # Open-issue counts per day over a window, segmented — the series behind the
  # trend chart.
  #
  # RECONSTRUCTED, NOT SAMPLED. There is no snapshot table and there does not need
  # to be one: an issue was open at the end of day D exactly when it was created
  # on or before D and closed after D (or not at all). So a set of issues carrying
  # `created_at` and `closed_at` *is* the history, and the series is a fold over
  # it. That is why Issues::GithubSnapshot fetches closed issues within the window
  # as well as open ones — without them the line would rise monotonically and
  # "are we burning down" would be unanswerable.
  #
  # ONE HONEST LIMITATION, STATED ON THE PAGE. The segment an issue belongs to is
  # its state TODAY — today's label, today's backlog row, today's rating. An issue
  # relabelled from divergent to convergent last week reads as convergent for the
  # whole history here. Segment membership is a classification of the issue, not
  # an event log of its labels, and doing better would mean a timeline request per
  # issue.
  class Trend
    # How the issues are split into series.
    SEGMENTS = %w[direction repo label].freeze
    DEFAULT_SEGMENT = "direction"

    # The bucket everything that is not one of the named segments falls into. Held
    # apart from the palette on purpose — "we have not classified this" is an
    # absence, and colouring it like a category invites reading it as one.
    OTHER = "other"

    # The categorical palette, in fixed slot order, so a series keeps its colour
    # when its neighbours are toggled off and hues are never generated. Slots 1-6
    # of the validated default categorical palette (blue, orange, aqua, yellow,
    # magenta, green); grey is reserved for the residual segment and is not a slot.
    #
    # Three of these sit below 3:1 contrast on a white surface, which obliges the
    # relief the chart ships anyway: every series is directly labelled at its right
    # end and every value is legible in the readout strip under the plot.
    PALETTE = %w[#2a78d6 #eb6834 #1baf7a #eda100 #e87ba4 #008300].freeze
    RESIDUAL_COLOR = "#6b7280"

    # Past this many named segments the tail folds into OTHER rather than taking a
    # generated hue.
    MAX_SERIES = PALETTE.length

    # At most this many x-axis ticks, so a 180-day window does not print 180 dates
    # on top of each other.
    MAX_TICKS = 7

    Series = Data.define(:key, :label, :color, :values) do
      def last_value = values.last.to_i
    end

    attr_reader :dates, :series, :window_days, :segment

    # @param issues [Array<Issues::GithubIssue>]
    # @param window_days [Integer] one of GithubSnapshot::WINDOWS
    # @param segment [String] one of SEGMENTS
    # @param direction_for [#call, nil] issue -> Issues::Direction::Resolution
    def initialize(issues:, window_days:, segment: DEFAULT_SEGMENT, direction_for: nil)
      @window_days = window_days
      @segment = SEGMENTS.include?(segment.to_s) ? segment.to_s : DEFAULT_SEGMENT
      @direction_for = direction_for
      @dates = build_dates
      issues = Array(issues)
      @label_rank = build_label_rank(issues)
      @series = build_series(issues)
    end

    # The total open count on each day. The segments partition the issue set, so
    # this is the whole population and not a fourth series competing with them —
    # the chart draws it as one neutral dashed line.
    def totals
      @totals ||= dates.each_index.map { |i| series.sum { |s| s.values[i] } }
    end

    def max_value = [ totals.max.to_i, 1 ].max

    def empty? = series.empty? || totals.sum.zero?

    # Which x positions get a printed date.
    def tick_indexes
      return (0...dates.length).to_a if dates.length <= MAX_TICKS

      step = (dates.length - 1).fdiv(MAX_TICKS - 1)
      (0...MAX_TICKS).map { |i| (i * step).round }.uniq
    end

    private

    def build_dates
      today = Date.current
      ((today - (window_days - 1))..today).to_a
    end

    # Labels ordered by how many issues carry them, so "segment by label" gives
    # each issue to its most widely-shared label and the result is a partition
    # rather than a set of overlapping counts that would not sum to the total.
    def build_label_rank(issues)
      counts = Hash.new(0)
      issues.each { |issue| (Array(issue.labels) - EXCLUDED_LABELS).each { |name| counts[name] += 1 } }
      counts.sort_by { |name, count| [ -count, name ] }.each_with_index.to_h { |(name, _), i| [ name, i ] }
    end

    def build_series(issues)
      order_segments(issues.group_by { |issue| segment_key(issue) }).each_with_index.map do |(key, members), index|
        Series.new(
          key: key,
          label: key,
          color: residual?(key) ? RESIDUAL_COLOR : PALETTE[index % PALETTE.length],
          values: daily_counts(members)
        )
      end
    end

    # How many of `members` were open at the end of each day in the window.
    #
    # One pass over the issues rather than one pass per day: each issue is open
    # over a single contiguous run of days, so it contributes +1 where the run
    # starts and -1 just past where it ends, and a running sum over those deltas
    # is the series. The per-day form — `dates.map { members.count { … } }` — is
    # the same answer at 180x the cost, which on 900 issues is the difference
    # between a page and a pause.
    def daily_counts(members)
      first_day = dates.first
      last_day = dates.last
      deltas = Array.new(dates.length + 1, 0)

      members.each do |issue|
        opened = issue.opened_on
        next if opened.nil? || opened > last_day

        closed_after = issue.last_open_on
        next if closed_after && closed_after < first_day

        from = opened <= first_day ? 0 : (opened - first_day).to_i
        to = closed_after.nil? || closed_after >= last_day ? dates.length - 1 : (closed_after - first_day).to_i
        next if to < from

        deltas[from] += 1
        deltas[to + 1] -= 1
      end

      running = 0
      dates.each_index.map { |i| running += deltas[i] }
    end

    # Biggest segment first, so the fixed palette slots go to the series a reader
    # is most likely to be looking at — and the residual segment always sits last
    # in grey, whatever its size.
    def order_segments(grouped)
      residual, named = grouped.partition { |key, _members| residual?(key) }
      named = named.sort_by { |_key, members| -members.length }

      if named.length > MAX_SERIES
        folded = named.drop(MAX_SERIES - 1).flat_map { |_key, members| members }
        residual = [ [ OTHER, folded + residual.flat_map { |_key, members| members } ] ]
        named = named.first(MAX_SERIES - 1)
      end

      named + residual.reject { |_key, members| members.empty? }
    end

    # Which key is "we could not classify this" depends on the segmentation, and
    # only one key ever is. Asking `key == UNRATED || key == OTHER` regardless
    # meant a repo carrying a GitHub label literally named `unrated` rendered two
    # grey series at once under `segment=label` — the label's own bucket and the
    # unlabelled one.
    def residual?(key) = key == (segment == "direction" ? Issues::Direction::UNRATED : OTHER)

    def segment_key(issue)
      case segment
      when "repo" then issue.repo.to_s.split("/").last
      when "label" then label_key(issue)
      else direction_key(issue)
      end
    end

    def direction_key(issue)
      return Issues::Direction::UNRATED if @direction_for.nil?

      @direction_for.call(issue).direction
    end

    # Direction labels are excluded because they ARE the `direction` segmentation;
    # leaving them in would make the two views the same picture with more lines.
    EXCLUDED_LABELS = (Issues::Direction::LABELS + [ "ready to merge" ]).freeze

    def label_key(issue)
      candidates = Array(issue.labels) - EXCLUDED_LABELS
      return OTHER if candidates.empty?

      candidates.min_by { |name| @label_rank.fetch(name, Float::INFINITY) }
    end
  end
end
