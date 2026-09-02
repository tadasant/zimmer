# frozen_string_literal: true

module WorkBacklog
  # Turn one queued item into an implementing session, and record which.
  #
  # This is the one place the queue becomes work. The groomer's pull calls it
  # once per item at `spot` class; the Issues view's "start now" button (Phase 2)
  # and its REST counterpart call it at `priority`. Both spawn exactly what the
  # groomer spawned by hand: a `zimmer-router` session, goal
  # `open-reviewed-green-pr`, prompted with the issue URL and the ask.
  #
  # ATOMIC. The session is created and the item marked `started` inside the
  # ranking lock, in one transaction: if the spawn raises the item stays queued,
  # and if the item turns out not to be queued nothing is spawned. Two pulls
  # racing for the same item serialise on the lock and the second sees `started`.
  class Start
    AGENT_ROOT = "zimmer-router"
    GOAL = "open-reviewed-green-pr"
    # What the groomer wrote into every session it pulled, so "which sessions did
    # the backlog produce" stays answerable from the session side too.
    SPAWNED_BY = "work-backlog"

    class NotQueued < StandardError; end

    Result = Data.define(:item, :session)

    class << self
      # @param item [WorkBacklogItem] must be queued
      # @param scheduling_class [String] SessionGenesis::SPOT or PRIORITY
      # @param acting_session [Session, nil] the session doing the starting — the
      #   groomer. Becomes the new session's parent, so it inherits genesis and
      #   sits in the same tree; and is recorded as `started_by_session`.
      # @param genesis [String, nil] for a parentless start: where it came from
      #   (SessionGenesis::API for REST; the web UI will pass WEB_UI)
      # @param precedence [Integer, nil] explicit spot-queue rank, or nil to sit
      #   just above the parent
      # @return [Result]
      def call(item:, scheduling_class:, acting_session: nil, genesis: nil, precedence: nil)
        unless SessionGenesis::CLASSES.include?(scheduling_class.to_s)
          raise ArgumentError, "scheduling_class must be one of #{SessionGenesis::CLASSES.join(', ')}"
        end

        Ranking.with_lock do
          item = WorkBacklogItem.lock.find(item.id)
          raise NotQueued, "#{item.key} is #{item.status}, not queued" unless item.queued?

          session = spawn_session(item, scheduling_class: scheduling_class, acting_session: acting_session,
                                genesis: genesis, precedence: precedence)
          item.mark_started!(session: session, by: acting_session)
          Ranking.rerank!

          Result.new(item: item, session: session)
        end
      end

      private

      def spawn_session(item, scheduling_class:, acting_session:, genesis:, precedence:)
        session = Session.create_from_agent_root!(
          agent_root_name: AGENT_ROOT,
          prompt: item.session_prompt,
          goal: GOAL,
          parent_session_id: acting_session&.id,
          # With a parent the genesis is inherited; without one the caller says
          # where the start came from, and a bare API call is `api`.
          genesis: acting_session ? nil : (genesis || SessionGenesis::API),
          scheduling_class: scheduling_class,
          precedence: precedence,
          custom_metadata: {
            "spawned_by" => SPAWNED_BY,
            "work_backlog_item_id" => item.id,
            "work_backlog_key" => item.key,
            "work_backlog_issue" => item.issue_url
          }.compact
        )

        # The title the groomer gave its sessions. `update_columns` so the
        # title-inference job, which keys on `auto_generated_title`, leaves the
        # stable, greppable one in place.
        session.update_columns(
          title: item.session_title,
          metadata: (session.metadata || {}).except("auto_generated_title")
        )
        session
      end
    end
  end
end
