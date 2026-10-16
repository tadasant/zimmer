# frozen_string_literal: true

module LiveConversations
  # The two live modes. They share everything — the conversation record, the
  # single-thread page, the tool bridge, delegation to Zimmer's MCP surface,
  # self-enabled catalog servers — and differ in three facts: which agent root's
  # AGENTS.md is the system prompt, which OpenAI model answers, and whether the
  # turns are typed or spoken.
  #
  # Which model answers is a Live setting (LiveSetting `text_model` and
  # `voice_model`), chosen on the Live settings page or by the live model itself,
  # and read on every turn; `model_key` names the one this mode reads. The
  # defaults — and why they are what they are — live with the setting:
  #
  # - Live Mode answers through Chat Completions on `gpt-6-luna` with
  #   `reasoning_effort: "none"`: OpenAI's most efficient current text model, and
  #   no reasoning pass before the first token. That is the latency a typed
  #   back-and-forth needs, and the instructions hand anything slow to a
  #   background session anyway. It is also the setting under which Chat
  #   Completions accepts function tools for this model.
  # - Live Voice speaks through the Realtime API on `gpt-realtime-2.1-mini`: the
  #   current realtime model with tool use at a fraction of the full model's
  #   audio price. `gpt-realtime-2.1` is the stronger choice on the settings page.
  Mode = Data.define(:key, :label, :agent_root, :model_key, :tagline) do
    def model = LiveSetting.current.effective(model_key)
    def voice? = key == "voice"
    def text? = key == "text"
    def to_param = key
  end
end
