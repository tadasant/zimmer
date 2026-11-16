# frozen_string_literal: true

module CycleTimesHelper
  # "1h 04m", "4m 10s", "12s", "0.4s" — compact enough for a table cell and a
  # tooltip, precise enough at every scale a cycle time spans.
  def cycle_duration(seconds)
    seconds = seconds.to_f
    return "#{seconds.round(1)}s" if seconds < 10
    return "#{seconds.round}s" if seconds < 60

    minutes, secs = seconds.round.divmod(60)
    return "#{minutes}m #{secs.to_s.rjust(2, '0')}s" if minutes < 60

    hours, minutes = minutes.divmod(60)
    return "#{hours}h #{minutes.to_s.rjust(2, '0')}m" if hours < 48

    days, hours = hours.divmod(24)
    "#{days}d #{hours}h"
  end

  def cycle_share(part, whole)
    return "0%" unless whole.to_f.positive?

    pct = part.to_f / whole * 100
    pct < 1 ? "<1%" : "#{pct.round}%"
  end

  def cycle_category_style(key)
    CycleTimes::Categories.css(key)
  end

  # The data a segment's hover tooltip reads. One place, so the stacked bars and
  # the Gantt lanes describe a segment in the same words.
  def cycle_segment_data(category:, seconds:, detail: nil, from: nil, to: nil, started_at: nil, session: nil)
    data = {
      cycle_segment: true,
      label: CycleTimes::Categories.label(category),
      duration: cycle_duration(seconds),
      detail: detail.to_s
    }
    if from && started_at
      data[:window] = "#{cycle_clock(started_at + from)} → #{cycle_clock(started_at + to)} (+#{cycle_duration(from)})"
    end
    data[:session] = session.to_s if session
    data
  end

  def cycle_clock(time)
    time.in_time_zone.strftime("%b %-d %H:%M:%S")
  end

  # Tick marks for a time axis `total` seconds long: about six, at a round step.
  def cycle_axis_ticks(total)
    total = total.to_f
    return [] unless total.positive?

    steps = [ 1, 5, 10, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10_800, 21_600, 43_200, 86_400 ]
    step = steps.find { |s| total / s <= 7 } || (total / 6).ceil
    (0..(total / step).floor).map { |i| i * step }
  end
end
