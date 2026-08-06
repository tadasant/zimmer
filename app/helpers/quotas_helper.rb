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

  def time_until_reset(reset_time)
    return "N/A" if reset_time.nil?

    diff = reset_time - Time.current
    return "Window reset" if diff <= 0

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
end
