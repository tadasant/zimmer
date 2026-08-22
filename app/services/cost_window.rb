# frozen_string_literal: true

# The time window every Costs figure is computed over, and the one place that
# turns request params into it.
#
# There are two ways to say "which window", and both have to round-trip: the
# one-click presets (24 hours, 7 days, ...) and an explicit from/to range picked
# off a calendar. Every drilldown link on the page has to carry whichever one the
# viewer chose, or clicking into a breakdown silently changes the window under
# them. Putting both behind one object is what makes `window.to_params` a thing a
# link can splat, rather than each link site re-deriving `days` and losing a
# custom range.
#
# Dates, not timestamps, on the custom side. The picker is a `<input type="date">`
# because that is the control a phone renders as a native calendar, so the input
# is a calendar day in the app's zone; `from` is its start and `to` is the END of
# its day, which is what "Aug 1 to Aug 3" means to the person who typed it.
class CostWindow
  # The one-click horizons, in the order they render.
  PRESETS = {
    1 => "24 hours",
    7 => "7 days",
    30 => "30 days",
    90 => "90 days",
    365 => "1 year"
  }.freeze

  # Bounded so a hand-typed `?days=100000` — or a from/to a decade apart — cannot
  # ask Postgres to scan the whole table and time out the page.
  MAX_DAYS = 365
  DEFAULT_DAYS = 7

  attr_reader :from, :to, :preset_days

  # @param params [ActionController::Parameters, Hash]
  def self.from_params(params)
    from = parse_date(params[:from])
    to = parse_date(params[:to])

    return custom(from, to) if from || to

    new(preset_days: clamp_days(params[:days]))
  end

  # An explicit calendar range. A missing end is "up to today"; a missing start is
  # the default window back from the end, so a half-filled form still resolves to
  # something rather than erroring.
  def self.custom(from, to)
    to ||= Date.current
    from ||= to - DEFAULT_DAYS
    from, to = to, from if from > to

    # Clamp the SPAN rather than rejecting the range: someone who types 2019 into
    # the start field wants "as far back as you go", not a validation error.
    from = to - (MAX_DAYS - 1) if (to - from).to_i >= MAX_DAYS

    new(from_date: from, to_date: to)
  end

  def self.clamp_days(raw)
    value = raw.to_i
    return DEFAULT_DAYS unless value.positive?
    value.clamp(1, MAX_DAYS)
  end

  def self.parse_date(raw)
    return nil if raw.blank?
    Date.parse(raw.to_s)
  rescue Date::Error
    nil
  end
  private_class_method :parse_date

  def initialize(preset_days: nil, from_date: nil, to_date: nil)
    if preset_days
      @preset_days = preset_days
      @to = Time.current
      @from = @to - preset_days.days
    else
      @from_date = from_date
      @to_date = to_date
      @from = from_date.in_time_zone.beginning_of_day
      @to = to_date.in_time_zone.end_of_day
    end
  end

  def custom? = @preset_days.nil?

  # The values the two `<input type="date">` fields render with. A preset window
  # pre-fills them with its own bounds, so opening the picker starts from what you
  # are already looking at instead of from blank.
  def from_date = @from_date || from.to_date
  def to_date = @to_date || to.to_date

  # What a link has to carry to keep this window. Splatted into path helpers.
  def to_params
    return { days: preset_days } unless custom?
    { from: from_date.iso8601, to: to_date.iso8601 }
  end

  def label
    return PRESETS.fetch(preset_days, "#{preset_days} days") unless custom?
    return from_date.strftime("%b %-d, %Y") if from_date == to_date
    "#{from_date.strftime("%b %-d")} – #{to_date.strftime("%b %-d, %Y")}"
  end

  # Whole days spanned, for prose that has to say "the last N days".
  def days = ((to - from) / 1.day).ceil.clamp(1, MAX_DAYS)

  def analytics = CostAnalytics.new(from: from, to: to)
end
