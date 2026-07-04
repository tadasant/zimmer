# frozen_string_literal: true

module QuotasHelper
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
    return utilization if utilization.nil? || reset_time.nil?
    return 0.0 if reset_time <= Time.current

    utilization
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
