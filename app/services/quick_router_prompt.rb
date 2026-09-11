# frozen_string_literal: true

# The prompt a Quick Router session starts from: the human's words, with a block
# in front of them describing what they were looking at when they typed.
#
# Two surfaces build it. The in-app chat bubble (SessionsController#chat_bubble)
# sends the page it is floating over. The browser extension
# (Api::V1::QuickRouterController) sends any page on the web, plus a pin — the
# spot the human clicked before typing, resolved to the element under it — so
# the agent can tell "this heading" from "somewhere on a 20,000-character page".
#
# The human's words go last and unchanged. Everything before them is written by
# Zimmer, which is why callers record `prompt` rather than the return value as
# the HumanMessage, and why SessionTitleJob names the session after `prompt`.
module QuickRouterPrompt
  module_function

  OPEN_TAG = "<context-about-user's-current-view>"
  CLOSE_TAG = "</context-about-user's-current-view>"

  # Server-side cap on the page, on every surface that sends one. The clients
  # cap at 20,000 before sending; this is the ceiling behind them.
  PAGE_CONTEXT_MAX_LENGTH = 50_000

  # Page coordinates and viewport sizes beyond this are not coordinates.
  PIN_COORDINATE_LIMIT = 10_000_000

  # The pin fields the prompt renders, in the order it renders them, with how
  # long each may be. Anything longer is cut, anything not listed is dropped:
  # the pin comes off the open web through an extension, so it is shaped here
  # rather than trusted.
  PIN_TEXT_LIMITS = {
    "selector" => 500,
    "tag" => 32,
    "text" => 1_000,
    "excerpt" => 4_000
  }.freeze
  PIN_NUMBER_FIELDS = %w[x y viewport_width viewport_height].freeze

  # @param prompt [String] the human's words
  # @param page_context [String, nil] the page, already reduced to markdown and capped
  # @param current_url [String, nil]
  # @param page_title [String, nil]
  # @param pin [Hash, nil] the pinned spot, as normalized by .normalize_pin
  # @return [String] `prompt` alone when there is nothing to say about the view
  def augment(prompt:, page_context: nil, current_url: nil, page_title: nil, pin: nil)
    return prompt if page_context.blank? && pin.blank?

    block = +"#{OPEN_TAG}\n"
    block << "URL: #{current_url}\n" if current_url.present?
    block << "Title: #{page_title}\n" if page_title.present?
    block << "\n" if current_url.present? || page_title.present?
    block << pin_section(pin) if pin.present?
    block << "#{page_context}\n" if page_context.present?
    block << CLOSE_TAG

    "#{block}\n\n#{prompt}"
  end

  # A pin as it arrives off the request, reduced to the fields the prompt uses.
  #
  # @param raw [Hash, ActionController::Parameters, nil]
  # @return [Hash, nil] string keys; nil when nothing usable was sent
  def normalize_pin(raw)
    raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
    return nil unless raw.is_a?(Hash)

    pin = {}
    PIN_NUMBER_FIELDS.each do |field|
      number = coordinate(raw[field] || raw[field.to_sym])
      pin[field] = number if number
    end
    PIN_TEXT_LIMITS.each do |field, limit|
      value = (raw[field] || raw[field.to_sym]).to_s.strip
      pin[field] = value.truncate(limit) if value.present?
    end
    pin.presence
  end

  def pin_section(pin)
    section = +"<pinned-element>\n"
    section << "The user dropped a pin on the page before typing — the message is about this spot.\n"
    if pin["x"] && pin["y"]
      section << "Position: (x=#{pin['x']}, y=#{pin['y']}) in page coordinates"
      section << ", viewport #{pin['viewport_width']}x#{pin['viewport_height']}" if pin["viewport_width"] && pin["viewport_height"]
      section << ". The coordinate is the gesture; the element below is what it landed on, and is the thing to trust if the two disagree.\n"
    end
    section << "Element: <#{pin['tag']}>\n" if pin["tag"]
    section << "Selector: #{pin['selector']}\n" if pin["selector"]
    section << "Text: #{pin['text']}\n" if pin["text"]
    section << "Surrounding content:\n#{pin['excerpt']}\n" if pin["excerpt"]
    section << "</pinned-element>\n\n"
    section
  end

  # An integer for anything that reads as a finite number within range; nil for
  # everything else ("abc", "", "1e400", NaN, an array).
  def coordinate(value)
    return nil if value.blank?

    number = Float(value)
    return nil unless number.finite? && number.abs <= PIN_COORDINATE_LIMIT

    number.round
  rescue ArgumentError, TypeError
    nil
  end

  private_class_method :pin_section, :coordinate
end
