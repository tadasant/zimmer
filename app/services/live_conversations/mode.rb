# frozen_string_literal: true

module LiveConversations
  # How a Live Mode conversation runs right now: typed or spoken. A conversation
  # is in one of the two at a time and can switch mid-thread; everything else —
  # the record, the thread, the agent root, the tool bridge — is shared. The two
  # differ in which OpenAI model answers and in the style the model is told to
  # answer in.
  #
  # Which model answers is a Live setting (LiveSetting `text_model` and
  # `voice_model`), chosen on the Live settings page or by the live model itself,
  # and read on every turn; `model_key` names the one this mode reads. The
  # defaults — and why they are what they are — live with the setting:
  #
  # - Typed answers through Chat Completions on `gpt-6-luna` with
  #   `reasoning_effort: "none"`: OpenAI's most efficient current text model, and
  #   no reasoning pass before the first token. That is the latency a typed
  #   back-and-forth needs, and the instructions hand anything slow to a
  #   background session anyway. It is also the setting under which Chat
  #   Completions accepts function tools for this model.
  # - Voice speaks through the Realtime API on `gpt-realtime-2.1-mini`: the
  #   current realtime model with tool use at a fraction of the full model's
  #   audio price. `gpt-realtime-2.1` is the stronger choice on the settings page.
  #
  # The style text comes from the agent root when it ships one (`style_path`,
  # read by RootInstructions); `default_style` is what Zimmer says when it does
  # not, so a root without the files still gets a mode-appropriate prompt.
  Mode = Data.define(:key, :label, :model_key, :default_style) do
    def model = LiveSetting.current.effective(model_key)
    def voice? = key == "voice"
    def text? = key == "text"
    def to_param = key

    # Where in the agent root this mode's style text lives, relative to its
    # subdirectory.
    def style_path = "modes/#{key}.md"
  end
end
