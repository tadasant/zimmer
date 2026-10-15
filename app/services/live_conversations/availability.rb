# frozen_string_literal: true

module LiveConversations
  # Can this mode start right now, and if not, why not — in words a human can
  # act on. The two prerequisites are the OpenAI key and the mode's agent root;
  # either PR (this app's, or the catalog's that adds the root) may land first,
  # so a missing root is an expected state with a readable answer, not a crash.
  class Availability
    attr_reader :mode

    def self.for(mode_key) = new(LiveConversations.mode(mode_key))

    def initialize(mode)
      @mode = mode
    end

    def key_configured? = @key_configured ||= OpenaiClient.configured?

    def root
      return @root if defined?(@root)

      @root = AgentRootsConfig.find(mode.agent_root)
    end

    def root_present? = !root.nil?

    def available? = key_configured? && root_present?

    def reasons
      list = []
      unless key_configured?
        list << "#{OpenaiClient::API_KEY_VARIABLE} is not set. Add an OpenAI API key on the Live page " \
                "(or in the Parameter Store) to turn #{mode.label} on."
      end
      unless root_present?
        list << "The catalog has no `#{mode.agent_root}` agent root yet. #{mode.label} reads its instructions " \
                "from that root's AGENTS.md, so it stays off until the catalog carries it."
      end
      list
    end

    def as_api_json
      {
        mode: mode.key,
        label: mode.label,
        agent_root: mode.agent_root,
        model: mode.model,
        available: available?,
        key_configured: key_configured?,
        root_present: root_present?,
        reasons: reasons
      }
    end
  end
end
