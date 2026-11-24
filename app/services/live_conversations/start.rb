# frozen_string_literal: true

module LiveConversations
  # Start a fresh conversation, ending the one that was open — Live Mode has one
  # current thread. It starts typed or spoken (`mode_key`) and can switch either
  # way later.
  #
  # It starts `active` when an earlier conversation on the same root was
  # prepared: it takes that one's instructions and the tool lists of the
  # root's default servers it holds, and LiveConversationPrepareJob reads them
  # again in the background (`refresh: true`), adding any default server the
  # earlier one did not have tools for. A call can mint its secret at once
  # rather than wait seconds on the read — preparing lists every default
  # server's tools, and one on a machine that is offline takes its whole
  # connect timeout to say so. With no earlier conversation to start from, it
  # is `preparing` until the job has read the root's AGENTS.md.
  #
  # With `standby_id`, the conversation started is the one kept ready for this
  # (Standby), so a call the app already has open on it is a call on the
  # conversation that is current. Asking again (`again`) for one already taken
  # answers with it, so a request whose answer was lost can be sent twice; one that
  # is gone is not missed, and the conversation started is a new one like any other.
  class Start
    class Unavailable < StandardError; end

    # @param client_surface [String, nil] the TurnSource surface of the client
    #   starting it (web, ios, carplay, mcp), so a delegation the live model makes
    #   can say where the person was.
    # @param standby_id [Integer, nil] the standby conversation to start from.
    # @param again [Boolean] the client says this tap may have been answered already.
    def self.call(mode_key = "text", client_surface: nil, standby_id: nil, again: false) = new(mode_key, client_surface:, standby_id:, again:).call

    # What a new conversation on `root` would start from, or nil when nothing on
    # it has been prepared yet.
    def self.seed(root) = Seed.from(prepared_before(root), defaults(root))

    # The newest conversation on this root whose instructions were read.
    def self.prepared_before(root)
      LiveConversation.where(agent_root: root.name, status: [ LiveConversation::ACTIVE, LiveConversation::ENDED ])
                      .where.not(instructions: [ nil, "" ]).order(id: :desc).first
    end

    def self.defaults(root) = Array(root.default_mcp_servers).map(&:to_s).select { |name| ServersConfig.find(name) }.uniq
    private_class_method :prepared_before

    def initialize(mode_key, client_surface: nil, standby_id: nil, again: false)
      @again = again
      @standby_id = standby_id.presence && Integer(standby_id, exception: false)
      @mode = LiveConversations.mode(mode_key)
      @client_surface = LiveConversation.normalize_client_surface(client_surface)
      @availability = Availability.current
    end

    # @return [LiveConversation]
    # @raise [Unavailable] with a message naming what is missing
    # @raise [KeyError] for a mode that is neither text nor voice
    def call
      raise Unavailable, @availability.reasons.join(" ") unless @availability.available?

      root = @availability.root
      seeded = nil
      taken = false
      conversation = LiveConversation.transaction do
        standby = LiveConversation.lock.find_by(id: @standby_id) if @standby_id
        # Taken already. The same tap asking again: it says so, or nobody has said
        # anything in it yet. One somebody is talking in was another device's New.
        if standby&.open? && (@again || standby.turns.none?)
          taken = true
          next standby
        end

        LiveConversation.unfinished.lock.each(&:end!)
        seeded = self.class.seed(root)
        attributes = {
          mode: @mode.key,
          agent_root: root.name,
          model: @mode.model,
          status: LiveConversation::PREPARING,
          mcp_servers: self.class.defaults(root),
          client_surface: @client_surface,
          **(seeded&.attributes || {})
        }
        if standby&.standby? && seeded
          standby.start_from_standby!(attributes)
          standby
        else
          LiveConversation.create!(**attributes, last_activity_at: Time.current)
        end
      end
      return conversation if taken

      if seeded&.missing&.any?
        LiveConversationPrepareJob.perform_later(conversation.id, refresh: true, adding: seeded.missing)
      elsif seeded
        LiveConversationPrepareJob.perform_later(conversation.id, refresh: true)
      else
        LiveConversationPrepareJob.perform_later(conversation.id)
      end
      conversation
    rescue ActiveRecord::RecordNotUnique
      # Another start won the race for the one open slot; that one is the
      # current conversation now.
      LiveConversation.current || raise
    end

    # What a new conversation takes from a prepared one: its instructions, and
    # each default server it has a tool list for. `missing` is the defaults it
    # had none for — dropped there, or not a default then — which the
    # background read tries again.
    Seed = Data.define(:attributes, :missing) do
      def self.from(prepared, defaults)
        return nil if prepared.nil?

        cache = prepared.mcp_tool_cache.is_a?(Hash) ? prepared.mcp_tool_cache : {}
        servers = defaults.select { |name| SelfSessionInjector.zimmer_server_name?(name) || cache.key?(name) }
        new(
          attributes: {
            status: LiveConversation::ACTIVE,
            instructions: prepared.instructions,
            instructions_source: prepared.instructions_source,
            mode_instructions: prepared.mode_instructions,
            mcp_servers: servers,
            mcp_tool_cache: cache.slice(*servers)
          },
          missing: defaults - servers
        )
      end
    end
  end
end
