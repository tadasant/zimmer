# frozen_string_literal: true

module GateDecisionsHelper
  # `artifact_url` and `producing_session_url` are promoted out of prose a gate
  # wrote, not out of a validated field, and GateDecisions::Entry says so: the
  # session key is "free text in both gates: usually a URL, often a URL followed
  # by a paragraph, sometimes absent". So the column can hold something that is
  # not a URL at all, and — since the ledger is machine-written and the browser
  # surface authenticates nobody — could hold a `javascript:` scheme.
  #
  # Both problems have the same answer: link it only when it IS an http(s) URL,
  # and otherwise show the text. A paragraph rendered as a dead link is the same
  # bug as a hostile scheme rendered as a live one, and neither is worth the
  # convenience of an unconditional `link_to`.
  SAFE_URL = %r{\Ahttps?://\S+\z}

  def gate_decision_url_link(value, class_name: "text-indigo-600 hover:text-indigo-800 break-all", **options)
    text = value.to_s.strip
    return tag.span("not recorded", class: "text-gray-400") if text.blank?
    return tag.span(text, class: "text-gray-700 break-words") unless text.match?(SAFE_URL)

    link_to(text, text, class: class_name, **options)
  end
end
