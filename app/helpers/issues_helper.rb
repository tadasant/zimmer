# frozen_string_literal: true

module IssuesHelper
  # The colours a direction pill wears, in one place, so the queue table, the
  # GitHub table and the count strip cannot disagree about what green means.
  DIRECTION_TONES = {
    Issues::Direction::CONVERGENT => "bg-emerald-100 text-emerald-800",
    Issues::Direction::DIVERGENT => "bg-violet-100 text-violet-800",
    Issues::Direction::UNRATED => "bg-gray-100 text-gray-500"
  }.freeze

  def issue_direction_tone(direction)
    DIRECTION_TONES.fetch(direction.to_s, "bg-gray-100 text-gray-700")
  end

  # "tadasant/zimmer" -> "zimmer". The owner used to be the same for every repo,
  # which is no longer true — `pulsemcp/air` sits beside the tadasant ones. The
  # short name is still what gets printed, because repo names are unique across
  # Issues::GithubSnapshot::REPOS and an owner column would repeat the same
  # string down five rows out of six. Where the owner matters it is one hover or
  # one click away: the per-repo cards link to `github.com/<owner>/<repo>/issues`
  # and the repo filter carries the full name as each option's title.
  def issue_repo_short(repo)
    repo.to_s.split("/").last
  end

  # An `https://github.com/owner/repo/issues/123` rendered as `repo#123`.
  def issue_short_key(url, fallback: nil)
    match = url.to_s.match(%r{github\.com/[^/]+/([^/]+)/issues/(\d+)})
    return fallback || url.to_s if match.nil?

    "#{match[1]}##{match[2]}"
  end

  # The SVG polyline for one series, in the plot's own coordinate system: x is the
  # day index and y is counted down from `max`, so the whole plot is
  # `viewBox="0 0 <days - 1> <max>"` and needs no scaling arithmetic here. The
  # stretching to the container is `preserveAspectRatio="none"`, which is why
  # every stroke carries `vector-effect="non-scaling-stroke"`.
  def issue_trend_points(values, max)
    values.each_with_index.map { |value, index| "#{index},#{(max - value.to_i)}" }.join(" ")
  end

  # About this many gridlines between zero and the top of the plot.
  TICK_COUNT = 5

  # The steps a y-axis is allowed to climb in, as multiples of a power of ten.
  # Restricted to numbers a reader adds up in their head — an axis that ticks in
  # 137s is arithmetic, not a scale.
  #
  # 1.25 is deliberately absent even though 125 and 1250 read fine: against a
  # power of ten it rounds to 13, so every plot topping out between 51 and 65
  # would have ticked 0 / 13 / 26 / 39 / 52.
  NICE_STEPS = [ 1, 1.5, 2, 2.5, 3, 4, 5, 10 ].freeze

  # The y gridline values for a plot whose top is `max`.
  #
  # The top of the plot stays at the largest value plotted — the line touches the
  # ceiling rather than floating below a rounded-up one — and the gridlines are
  # round numbers under it. Forcing `max` itself into the list is what produces an
  # axis reading 0 / 130 / 260 / 390 / 500, whose last gap is a different size
  # from the others and reads as a mistake.
  def issue_trend_y_ticks(max)
    max = [ max.to_i, 1 ].max
    return (0..max).to_a if max <= TICK_COUNT

    step = NICE_STEPS.map { |m| (m * 10**Math.log10(max.fdiv(TICK_COUNT)).floor).ceil }
                     .find { |candidate| candidate >= max.fdiv(TICK_COUNT) }
    (0..max).step(step).to_a
  end

  # Where a value sits in the plot box, as a CSS percentage — used to place the
  # HTML overlay (crosshair, per-series dots, direct labels) over the SVG. HTML
  # rather than SVG because text inside a `preserveAspectRatio="none"` viewBox is
  # stretched with it, which on a phone renders the axis unreadable.
  def issue_trend_x_percent(index, count)
    return 0.0 if count <= 1

    (index.to_f / (count - 1)) * 100
  end

  def issue_trend_y_percent(value, max)
    return 100.0 if max.zero?

    (1 - (value.to_f / max)) * 100
  end

  # "4 minutes ago", or "just now" for a read taken this minute.
  def issue_snapshot_age(snapshot)
    seconds = snapshot.stale_seconds
    return "just now" if seconds < 60

    "#{distance_of_time_in_words(seconds)} ago"
  end

  # EVERY URL THIS PAGE LINKS GOES THROUGH HERE.
  #
  # `issue_url` and `payload.gate_session` are written by agents, not by a
  # validated form: WorkBacklogItem only checks `issue_url`'s length, and
  # `gate_session` is free text a gate wrote — usually a URL, sometimes a URL
  # followed by a paragraph, often absent. Any session holding the fleet's shared
  # API key can put a `javascript:` scheme in either, and Zimmer's browser surface
  # authenticates nobody, so an unguarded `link_to` would run it in the operator's
  # browser. There is no CSP in this app to catch it afterwards.
  #
  # So a value is linked only when it IS an http(s) URL, and rendered as text
  # otherwise: a paragraph rendered as a dead link is the same bug as a hostile
  # scheme rendered as a live one. Same rule, and the same regex, as
  # GateDecisionsHelper — this page renders the same class of value the gate
  # decision ledger does.
  def issue_safe_link(value, text = nil, **options)
    url = value.to_s.strip
    label = text.presence || url
    return tag.span(label, class: options[:class]) unless url.match?(GateDecisionsHelper::SAFE_URL)

    link_to(label, url, target: "_blank", rel: "noopener noreferrer", **options)
  end

  # The gate session that cleared an item, when the gate recorded one and
  # recorded it as a URL.
  def issue_gate_session_link(value)
    return nil unless value.to_s.strip.match?(GateDecisionsHelper::SAFE_URL)

    issue_safe_link(value, "gate session", class: "text-[11px] text-indigo-600 hover:text-indigo-800")
  end

  # The tooltip on the pin field: what precedence means, and where each cost band
  # sits. Built from WorkBacklog::Ranking rather than written out, so a band that
  # moves does not leave a wrong number on fifty rows.
  def pin_precedence_hint(key)
    bands = WorkBacklogItem::COSTS.map do |cost|
      band = WorkBacklog::Ranking.band_for(cost)
      "#{cost} #{band.floor}\u2013#{band.ceiling}"
    end

    "Precedence to pin #{key} at \u2014 higher is pulled sooner. Bands: #{bands.join(', ')}."
  end
end
