# frozen_string_literal: true

# Live Mode: one continuous conversation with a fast OpenAI model, typed or
# spoken. Voice is not a separate mode: a conversation is in one of two
# modalities at a time (LiveConversations::Mode) and can switch between them
# mid-thread. Every conversation reads the one agent root below.
module LiveConversations
  LABEL = "Live Mode"
  AGENT_ROOT = "live-mode"
  TAGLINE = "One continuous conversation with Zimmer, typed or spoken. Quick things it answers itself; " \
            "anything slower it hands to a background session."

  MODES = {
    "text" => Mode.new(
      key: "text", label: "Text", model_key: :text_model,
      default_style: <<~TEXT
        This conversation is typed and read on a screen right now. Longer answers are fine when they help:
        lists, short snippets of text or code, links to sessions and PRs, and light markdown. Still put the
        answer first and offer detail rather than writing it all out unasked.
      TEXT
    ),
    "voice" => Mode.new(
      key: "voice", label: "Voice", model_key: :voice_model,
      default_style: <<~TEXT
        This conversation is spoken right now: you are heard, not read. Keep turns to one to three short,
        conversational sentences, then stop and let them answer. Never read out markdown, lists, URLs, IDs
        or code; call a session by what it does. Expect to be interrupted: if they talk over you, drop the
        rest and answer the new thing. If you did not catch something, say so and ask once.
      TEXT
    )
  }.freeze

  def self.mode(key) = MODES.fetch(key.to_s)
  def self.mode_keys = MODES.keys
end
