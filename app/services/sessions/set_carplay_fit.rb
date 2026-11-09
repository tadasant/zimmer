# frozen_string_literal: true

module Sessions
  # Writes a session's CarPlay fit — and nothing else.
  #
  # Every writer routes through here: the status-summary harvest (`auto`, or
  # `carplay` for an engaged session), the web UI (`human`), the REST endpoint,
  # the `set_carplay_fit` MCP action on both the full and the self-session
  # surface, and CarPlay engagement (Sessions::RecordCarplayEngagement). That is what makes the
  # precedence rule a rule rather than a convention: at the same transcript
  # position a `human` mark beats `assistant` and `session`, which beat `auto`,
  # and a mark written against a later position always wins. A write the rule
  # refuses is reported, not raised — the caller that loses is usually the
  # summary fork, and a lost precedence contest is not an error it should log.
  #
  # Five columns, one `update!`. It does not touch `status`, precedence, the
  # spot queue or any trigger — see SessionCarplayFit for the contract.
  class SetCarplayFit
    class Error < StandardError; end

    Result = Struct.new(:applied, :message, :session, keyword_init: true) do
      def applied? = applied
    end

    # @param session [Session]
    # @param fit [String, nil] "carplay_ok", "laptop_only", or nil / "clear" to
    #   remove the mark
    # @param source [String] who is writing: one of SessionCarplayFit::SOURCES
    # @param reason [String, nil] one of SessionCarplayFit::REASONS; cleared with
    #   the fit
    # @param line_count [Integer, nil] the transcript position the judgement was
    #   made against. Defaults to the session's current line count. The summary
    #   harvest passes the line count its summary was generated from, so a mark
    #   and the blurb it came from are stamped alike.
    # @return [Result]
    # @raise [Error] on a value off the lists
    def self.call(session:, fit:, source:, reason: nil, line_count: nil)
      new(session: session, fit: fit, source: source, reason: reason, line_count: line_count).call
    end

    def initialize(session:, fit:, source:, reason: nil, line_count: nil)
      @session = session
      @fit = normalize_fit(fit)
      @source = source.to_s.strip
      @reason = reason.to_s.strip.presence
      @line_count = line_count.nil? ? session.transcript_line_count.to_i : line_count.to_i
    end

    attr_reader :session, :fit, :source, :reason, :line_count

    def call
      validate!

      if (standing = standing_mark_that_outranks_this_write)
        return Result.new(applied: false, session: session, message: standing)
      end
      return keep_the_sticky_default if reconfirms_the_sticky_default?

      @replacing_sticky = session.carplay_fit_sticky?
      session.update!(
        carplay_fit: fit,
        carplay_fit_reason: fit.nil? ? nil : reason,
        carplay_fit_source: fit.nil? ? nil : source,
        carplay_fit_set_at: fit.nil? ? nil : Time.current,
        carplay_fit_line_count: fit.nil? ? nil : line_count
      )
      note_on_timeline

      Result.new(applied: true, session: session, message: fit.nil? ? "CarPlay fit cleared." : "CarPlay fit set to #{fit}.")
    end

    private

    def normalize_fit(value)
      text = value.to_s.strip
      return nil if text.empty? || text == "clear"

      text
    end

    def validate!
      unless fit.nil? || SessionCarplayFit::FITS.include?(fit)
        raise Error, "Unknown carplay_fit \"#{fit}\". Valid values: #{SessionCarplayFit::FITS.join(', ')}, or \"clear\"."
      end
      unless SessionCarplayFit::SOURCES.include?(source)
        raise Error, "Unknown carplay_fit source \"#{source}\". Valid values: #{SessionCarplayFit::SOURCES.join(', ')}."
      end
      if source == SessionCarplayFit::SOURCE_CARPLAY && fit != SessionCarplayFit::CARPLAY_OK
        raise Error, "A carplay-source mark is the CarPlay-engagement default and is only ever carplay_ok."
      end
      if reason && !SessionCarplayFit::REASONS.include?(reason)
        raise Error, "Unknown carplay_fit reason \"#{reason}\". Valid values: #{SessionCarplayFit::REASONS.join(', ')}."
      end
    end

    # The sentence explaining why this write is refused, or nil when it may land.
    #
    # A standing mark outranks a write when it was made against the same or a
    # later transcript position AND its source ranks strictly higher. Equal rank
    # overwrites — a human correcting a human, the summary fork re-running at the
    # same line — and a lower-ranked standing mark is simply replaced.
    def standing_mark_that_outranks_this_write
      return nil if session.carplay_fit.blank? || session.carplay_fit_line_count.nil?
      return nil if session.carplay_fit_line_count < line_count

      standing_rank = SessionCarplayFit::SOURCE_RANK.fetch(session.carplay_fit_source, -1)
      return nil if standing_rank <= SessionCarplayFit::SOURCE_RANK.fetch(source)

      "Kept the standing #{session.carplay_fit_source} mark (#{session.carplay_fit_summary}): it was written " \
        "against the same or a later transcript position and a #{session.carplay_fit_source} mark outranks a #{source} one."
    end

    # An automatic or engagement `carplay_ok` landing on a session that already
    # holds the sticky CarPlay default agrees with it. Rewriting would restamp
    # the mark and log a timeline line on every rest for no change, so the
    # standing mark is kept — gaining the judgement's reason when it had none
    # or a different one.
    def reconfirms_the_sticky_default?
      session.carplay_fit_sticky? &&
        fit == SessionCarplayFit::CARPLAY_OK &&
        [ SessionCarplayFit::SOURCE_AUTO, SessionCarplayFit::SOURCE_CARPLAY ].include?(source)
    end

    def keep_the_sticky_default
      session.update!(carplay_fit_reason: reason) if reason && reason != session.carplay_fit_reason
      Result.new(applied: false, session: session,
                 message: "Kept the standing CarPlay-engagement mark (#{session.carplay_fit_summary}): it already says carplay_ok.")
    end

    # One line on the session's own timeline for every write a person or an
    # agent makes, so the history of who marked what survives the overwrite.
    # The automatic mark is deliberately not logged: it is written at every rest,
    # and a timeline line per rest is noise next to the summary that carries the
    # same judgement. Best-effort — a timeline write must not fail the mark.
    # The one automatic write that IS logged is a demotion of the sticky CarPlay
    # default: the driver's view just lost a session they engaged, and the
    # timeline is where they can see why.
    def note_on_timeline
      return if source == SessionCarplayFit::SOURCE_AUTO && !@replacing_sticky

      content = if fit.nil?
        "CarPlay fit cleared by #{source}"
      elsif @replacing_sticky && fit == SessionCarplayFit::LAPTOP_ONLY
        "CarPlay fit demoted from the CarPlay-engagement default to #{SessionCarplayFit::LABELS.fetch(fit)}" \
          "#{reason ? " (#{SessionCarplayFit::REASON_LABELS.fetch(reason)})" : ''} by #{source}"
      else
        "CarPlay fit set to #{SessionCarplayFit::LABELS.fetch(fit)}#{reason ? " (#{SessionCarplayFit::REASON_LABELS.fetch(reason)})" : ''} by #{source}"
      end
      session.logs.create!(content: content, level: "info")
    rescue StandardError => e
      Rails.logger.error("[Sessions::SetCarplayFit] Failed to note the mark on session #{session.id}'s timeline: #{e.message}")
    end
  end
end
