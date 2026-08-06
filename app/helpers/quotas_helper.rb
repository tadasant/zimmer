# frozen_string_literal: true

module QuotasHelper
  # One side of a rotation-history row. A deleted account keeps its email —
  # preserved on the event itself — and is labelled as deleted, so the row reads
  # as "the pool moved off an account that no longer exists" rather than as the
  # pool having moved from nowhere. An em dash means there genuinely was no
  # account on that side (a bootstrap, or an activation with nothing current).
  def rotation_account_label(email, deleted: false)
    return "—" if email.blank?
    return email unless deleted

    safe_join([
      email,
      tag.span("deleted", class: "ml-1 inline-flex items-center px-1.5 py-0.5 rounded-full text-[10px] font-medium bg-gray-100 text-gray-500")
    ])
  end

  def utilization_bar_color(value)
    return "bg-gray-300" if value.nil?

    if value < 0.6
      "bg-green-500"
    elsif value < 0.85
      "bg-yellow-500"
    else
      "bg-red-500"
    end
  end

  def utilization_bg_color(value)
    return "bg-gray-100" if value.nil?

    if value < 0.6
      "bg-green-50"
    elsif value < 0.85
      "bg-yellow-50"
    else
      "bg-red-50"
    end
  end

  def utilization_percentage_text(value)
    return "N/A" if value.nil?

    "#{(value * 100).round(1)}%"
  end

  # The status badge for one window on an account card, or nothing.
  #
  # A recorded status describes the window that was open when the reading was
  # taken. Once that window's reset time has passed the window is gone, and the
  # status is no longer a fact about the account — the same rule
  # ClaudeAccountQuotaSnapshot.effective_utilization applies to the counter, and
  # ClaudeAccountQuotaSnapshot#seven_day_window_spent? applies to the status.
  # Keeping the badge would leave the card claiming "Rejected" beside the 0.0%
  # and the green "Window reset" line the same snapshot renders. Drop it and let
  # that line carry the state; a fresh probe supplies the next real status.
  #
  # Any status, not only a blocking one. "Allowed" read off a window that has
  # since cleared is no more a fact about the account than "Rejected" is.
  #
  # This is the entry point the card uses. quota_status_badge below renders the
  # badge itself and applies no such rule, so calling it directly from a view is
  # how the stale badge comes back.
  def window_status_badge(status, reset_time)
    return if reset_time && reset_time <= Time.current

    quota_status_badge(status)
  end

  # The line under a utilization bar saying where the window stands: reset
  # already, or how long until it will be. One definition, because the two
  # branches have to agree on what "passed" means.
  #
  # The card's only route to time_until_reset, which is why that helper's own
  # nil and already-passed guards read as belt-and-braces here: this line has
  # answered both before it ever calls through.
  def reset_window_line(reset_time)
    return if reset_time.nil?

    if reset_time <= Time.current
      tag.p("Window reset", class: "mt-0.5 text-xs text-green-500")
    else
      tag.p("Resets in #{time_until_reset(reset_time)}", class: "mt-0.5 text-xs text-gray-400")
    end
  end

  def quota_status_badge(status)
    if status == "allowed"
      tag.span("Allowed",
        class: "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-green-100 text-green-800")
    else
      tag.span(status&.titleize || "Unknown",
        class: "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-red-100 text-red-800")
    end
  end

  # Returns the effective utilization for display purposes.
  # When a window's reset time has passed, the utilization is effectively 0
  # because the sliding window has cleared — showing stale high values would
  # be misleading.
  def effective_utilization(utilization, reset_time)
    ClaudeAccountQuotaSnapshot.effective_utilization(utilization, reset_time)
  end

  # True when an account's weekly allowance is gone. The rule itself lives on
  # ClaudeAccountQuotaSnapshot, because rotation and the quota-reset checker act
  # on the same reading — see ClaudeAccountQuotaSnapshot#seven_day_window_spent?.
  def seven_day_window_spent?(snapshot)
    return false if snapshot.nil?

    snapshot.seven_day_window_spent?
  end

  # The 5-hour utilization an account contributes to the pool view.
  #
  # An account whose weekly allowance is spent cannot serve a request no matter
  # how much 5-hour headroom its counter reports, so it counts as fully utilized.
  # Anywhere else this is the raw 5-hour figure, which keeps the number to one
  # statement: 5-hour utilization, with weekly-blocked accounts counted as 100%.
  #
  # The correction runs one way. The 7-day window subsumes the 5-hour one: an
  # account at its 5-hour cap is idle for minutes and then serves again, so it
  # must never be reported as having burned its week.
  def pool_utilization_5h(snapshot)
    return nil if snapshot.nil?
    return 1.0 if seven_day_window_spent?(snapshot)

    effective_utilization(snapshot.utilization_5h, snapshot.reset_5h)
  end

  # True when an account's 5-hour counter reads as headroom the account cannot
  # spend, because its weekly allowance is gone. This is the case where the
  # pool 5-hour figure and the account's own 5-hour bar disagree.
  def five_hour_headroom_unusable?(snapshot)
    return false unless seven_day_window_spent?(snapshot)

    eff_5h = effective_utilization(snapshot.utilization_5h, snapshot.reset_5h)
    eff_5h.nil? || eff_5h < 1.0
  end

  # A human duration until a window resets. Never returns an empty string: the
  # caller interpolates it after a label ("Resets in ..."), so a blank answer
  # renders as a label with nothing after it.
  #
  # Minutes are the finest unit shown, which leaves the last minute before a
  # reset with no whole unit to report — every component floors to zero and the
  # join produces "". That last minute is named explicitly instead.
  def time_until_reset(reset_time)
    return "N/A" if reset_time.nil?

    diff = reset_time - Time.current
    return "Window reset" if diff <= 0
    return "< 1m" if diff < 1.minute

    days = (diff / 1.day).floor
    hours = ((diff % 1.day) / 1.hour).floor
    minutes = ((diff % 1.hour) / 1.minute).floor

    parts = []
    parts << "#{days}d" if days > 0
    parts << "#{hours}h" if hours > 0
    parts << "#{minutes}m" if minutes > 0
    parts.join(" ")
  end

  def subscription_type_badge(type)
    colors = case type&.downcase
    when /max/
      "bg-purple-100 text-purple-800"
    when /pro/
      "bg-blue-100 text-blue-800"
    else
      "bg-gray-100 text-gray-800"
    end
    tag.span(type&.titleize || "Unknown",
      class: "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium #{colors}")
  end

  def account_status_badge(status)
    case status.to_s
    when "active"
      tag.span("Active",
        class: "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-green-100 text-green-800")
    when "quota_exceeded"
      tag.span("Quota Exceeded",
        class: "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-red-100 text-red-800")
    when "needs_reauth"
      tag.span("Needs Reauth",
        class: "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-yellow-100 text-yellow-800")
    else
      tag.span(status.to_s.titleize,
        class: "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-gray-100 text-gray-800")
    end
  end

  # The spot gate renders each genesis kind twice — a stacked card below the `sm`
  # breakpoint, a table row above it — because a four-column table does not fit a
  # phone. Both renderings read their state from here so the two cannot disagree
  # about which class a kind carries or which class a click would move it to.
  #
  # Returns [current_class, target_class, overridden?, badge_css].
  def genesis_kind_state(kind, genesis_classes)
    current = genesis_classes[kind.key]
    target = current == SessionGenesis::PRIORITY ? SessionGenesis::SPOT : SessionGenesis::PRIORITY
    badge = if current == SessionGenesis::PRIORITY
      "bg-indigo-100 text-indigo-800"
    else
      "bg-gray-100 text-gray-700"
    end

    [ current, target, current != kind.default_class, badge ]
  end
end
