# frozen_string_literal: true

# Renders a session's conversation as the plain text a summarizer is given.
#
# Two callers need the same rendering, which is why it is not a private method
# on either of them:
#
#   * the fork path, when the fork cannot be resumed from a runtime transcript
#     file (Codex rollouts have no deterministic path) and so must be handed the
#     copied conversation inline;
#   * the headless path, which has no session of its own at all and is ALWAYS
#     working from this text.
#
# Truncation keeps the TAIL. A status blurb answers "where does this stand",
# which is the end of the conversation — so when a long session does not fit,
# the beginning is what goes.
module StatusSummaryTranscriptExcerpt
  # The cap on rendered conversation handed to a summarizer. Sized for the fork
  # prompt, where it is one section of a message to an agent with a full context
  # window; the headless path passes its own, smaller cap, because a one-shot
  # completion on a small model has less room and needs none of it.
  DEFAULT_MAX_CHARS = 80.kilobytes

  OMISSION = "\n\n[Earlier transcript truncated]\n\n"

  module_function

  # @param session [Session] the session whose transcript to render
  # @param max_chars [Integer] cap on the returned text
  # @return [String] the rendered tail of the conversation, or "" when there is
  #   nothing renderable
  def render(session, max_chars: DEFAULT_MAX_CHARS)
    rendered = TranscriptTextRenderer.render(normalized(session)).strip
    return "" if rendered.blank?

    truncate_to_tail(rendered, max_chars)
  end

  def normalized(session)
    normalizer = TranscriptRuntime.normalizer_for(session)

    session.parsed_transcript.flat_map do |raw_event|
      normalizer.normalize(raw_event, session: session, transcript_index: raw_event["_transcript_index"])
    end
  end

  def truncate_to_tail(rendered, max_chars)
    return rendered if rendered.length <= max_chars

    "#{OMISSION}#{rendered.last(max_chars - OMISSION.length)}"
  end
end
