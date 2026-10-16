# frozen_string_literal: true

module LiveConversations
  # The two live modes. They share everything — the conversation record, the
  # single-thread page, the tool bridge, delegation to Zimmer's MCP surface,
  # self-enabled catalog servers — and differ in three facts: which agent root's
  # AGENTS.md is the system prompt, which OpenAI model answers, and whether the
  # turns are typed or spoken.
  #
  # Models are env-overridable so a newer snapshot is a config change, not a deploy:
  #
  # - Live Mode answers through Chat Completions on `gpt-6-luna` with
  #   `reasoning_effort: "none"`: OpenAI's most efficient current text model, and
  #   no reasoning pass before the first token. That is the latency a typed
  #   back-and-forth needs, and the instructions hand anything slow to a
  #   background session anyway. It is also the setting under which Chat
  #   Completions accepts function tools for this model.
  # - Live Voice speaks through the Realtime API on `gpt-realtime-2.1-mini`: the
  #   current realtime model with tool use at a fraction of the full model's
  #   audio price — the live agent dispatches and narrates; the thinking happens
  #   in the sessions it starts.
  Mode = Data.define(:key, :label, :agent_root, :model_env, :default_model, :tagline) do
    def model = ENV.fetch(model_env, "").presence || default_model
    def voice? = key == "voice"
    def text? = key == "text"
    def to_param = key
  end
end
