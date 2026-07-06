# frozen_string_literal: true

module HealthHelper
  def status_banner_class(status)
    case status.status
    when :healthy
      "bg-green-50 border border-green-200"
    when :warning
      "bg-yellow-50 border border-yellow-200"
    when :critical
      "bg-red-50 border border-red-200"
    else
      "bg-gray-50 border border-gray-200"
    end
  end

  def status_text_class(status)
    case status.status
    when :healthy
      "text-green-800"
    when :warning
      "text-yellow-800"
    when :critical
      "text-red-800"
    else
      "text-gray-800"
    end
  end

  def status_subtext_class(status)
    case status.status
    when :healthy
      "text-green-600"
    when :warning
      "text-yellow-600"
    when :critical
      "text-red-600"
    else
      "text-gray-600"
    end
  end

  def status_icon(status)
    case status.status
    when :healthy
      content_tag(:svg, class: "h-5 w-5 text-green-400", xmlns: "http://www.w3.org/2000/svg", viewBox: "0 0 20 20", fill: "currentColor") do
        content_tag(:path, nil, fill_rule: "evenodd", d: "M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z", clip_rule: "evenodd")
      end
    when :warning
      content_tag(:svg, class: "h-5 w-5 text-yellow-400", xmlns: "http://www.w3.org/2000/svg", viewBox: "0 0 20 20", fill: "currentColor") do
        content_tag(:path, nil, fill_rule: "evenodd", d: "M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z", clip_rule: "evenodd")
      end
    when :critical
      content_tag(:svg, class: "h-5 w-5 text-red-400", xmlns: "http://www.w3.org/2000/svg", viewBox: "0 0 20 20", fill: "currentColor") do
        content_tag(:path, nil, fill_rule: "evenodd", d: "M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z", clip_rule: "evenodd")
      end
    else
      content_tag(:svg, class: "h-5 w-5 text-gray-400", xmlns: "http://www.w3.org/2000/svg", viewBox: "0 0 20 20", fill: "currentColor") do
        content_tag(:path, nil, fill_rule: "evenodd", d: "M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z", clip_rule: "evenodd")
      end
    end
  end

  def status_badge(status)
    badge_class = case status.status
    when :healthy
      "bg-green-100 text-green-800"
    when :warning
      "bg-yellow-100 text-yellow-800"
    when :critical
      "bg-red-100 text-red-800"
    else
      "bg-gray-100 text-gray-800"
    end

    content_tag(:span, status.status.to_s.capitalize, class: "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium #{badge_class}")
  end

  def session_status_color(status)
    case status.to_s
    when "running"
      "bg-blue-100 text-blue-800"
    when "waiting"
      "bg-gray-100 text-gray-800"
    when "needs_input"
      "bg-yellow-100 text-yellow-800"
    when "failed"
      "bg-red-100 text-red-800"
    when "archived"
      "bg-gray-100 text-gray-500"
    else
      "bg-gray-100 text-gray-800"
    end
  end
end
