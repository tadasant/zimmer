# frozen_string_literal: true

module LiveConversations
  # Can Live Mode start right now, and if not, why not — in words a human can
  # act on. The two prerequisites are the OpenAI key and the `live-mode` agent
  # root. The root lives in whatever catalog a deployment runs, which may not
  # carry it, so a missing root is an expected state with a readable answer, not
  # a crash. Typing and talking share both, so they are available together.
  class Availability
    def self.current = new

    def key_configured? = @key_configured ||= OpenaiClient.configured?

    def root
      return @root if defined?(@root)

      @root = AgentRootsConfig.find(AGENT_ROOT)
    end

    def root_present? = !root.nil?

    def available? = key_configured? && root_present?

    def reasons
      list = []
      unless key_configured?
        list << "#{OpenaiClient::API_KEY_VARIABLE} is not set. Add an OpenAI API key on the Live page " \
                "(or in the Parameter Store) to turn #{LABEL} on."
      end
      unless root_present?
        list << "The catalog has no `#{AGENT_ROOT}` agent root yet. #{LABEL} reads its instructions " \
                "from that root's AGENTS.md, so it stays off until the catalog carries it."
      end
      list
    end

    # `modes` lists each way a conversation can run, with its model; the
    # prerequisites are shared, so each entry repeats them.
    def as_api_json
      shared = { agent_root: AGENT_ROOT, available: available?, key_configured: key_configured?, root_present: root_present?, reasons: reasons }
      {
        label: LABEL,
        **shared,
        modes: MODES.values.map { |mode| { mode: mode.key, label: mode.label, model: mode.model, **shared } }
      }
    end
  end
end
