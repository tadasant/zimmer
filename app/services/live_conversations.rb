# frozen_string_literal: true

# Live Mode and Live Voice. The namespace holds the two modes; see
# LiveConversations::Mode for what differs between them, and LiveConversation
# for the record they share.
module LiveConversations
  MODES = {
    "text" => Mode.new(
      key: "text", label: "Live Mode", agent_root: "live-mode",
      model_key: :text_model,
      tagline: "One continuous typed conversation that hands real work to Zimmer."
    ),
    "voice" => Mode.new(
      key: "voice", label: "Live Voice", agent_root: "live-voice",
      model_key: :voice_model,
      tagline: "Talk to Zimmer. It answers out loud and hands real work to background sessions."
    )
  }.freeze

  def self.mode(key) = MODES.fetch(key.to_s)
  def self.mode_keys = MODES.keys
end
