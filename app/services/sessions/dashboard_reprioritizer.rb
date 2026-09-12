# frozen_string_literal: true

module Sessions
  # The Reprioritize button on the dashboard's User view.
  #
  # == One session, reused, not one per click
  #
  # The button is meant to be pressed whenever the board looks wrong, which on a
  # busy day is several times. A session per press would leave a trail of them in
  # the human's own action queue — the exact problem the User view exists to fix —
  # and each one would start cold, having to re-learn the board from scratch.
  #
  # So the button fires a TRIGGER, and the trigger reuses its session. That is
  # Zimmer's existing durable-session mechanism and none of it is reimplemented
  # here: `reuse_session` + `last_session_id` is what a wake-up trigger and a
  # recurring Slack trigger already use, Trigger#follow_up_session! decides between
  # delivering the prompt now and queueing it for the next turn boundary, and
  # `resuscitate_archived` brings the session back if it archived itself. The
  # second press lands as a follow-up in a conversation that already knows what
  # this board is and what it did last time.
  #
  # == Why the trigger is disabled
  #
  # It has a schedule condition because a Trigger must have at least one, and it
  # is `disabled` because it must never fire on its own — this is a template a
  # button invokes, not a schedule. Every automatic firing path filters on
  # `status: "enabled"`; Triggers::ManualFire deliberately does not, which is the
  # same thing the Invoke button on the trigger page relies on.
  #
  # The condition is RECURRING rather than one-time, and that matters: a trigger
  # whose every condition is a one-time schedule is a `one_time_reuse_trigger?`,
  # which changes what happens when the target session is gone (it skips instead
  # of spawning a fresh one) and makes the row a candidate for
  # CleanupStaleTriggersJob's one-shot sweeps.
  #
  # == Seeded lazily
  #
  # `find_or_create` on first press rather than a seed or a post-deploy task,
  # because the row has to exist on a fresh install and after someone deletes it
  # from /triggers, and a lazy create heals both without anybody reaching for a
  # shell on the box.
  class DashboardReprioritizer
    TRIGGER_NAME = "Dashboard reprioritizer"
    AGENT_ROOT = "dashboard-reprioritizer"

    # The prompt the session is started — and re-started — with.
    #
    # It names the two tools rather than describing the board, because the board
    # changes between presses and the tools are how it is read. What it does spell
    # out is the ranking policy, which is the part only the human can supply.
    PROMPT_TEMPLATE = <<~PROMPT.strip
      A human has pressed **Reprioritize** on the Zimmer dashboard's User view. Re-rank that board so the rows they are most likely to want next are at the top.

      ## How to read the board

      Call `get_user_view`. It returns the board in the order it is currently drawn, with everything each row shows: title, status, scheduling class, precedence, agent root, the generated status summary, and the session's most recent PR with its state and CI verdict. Page through it — do not guess at rows you have not read. If the board is large, lower `summary_chars` rather than skipping pages.

      Do NOT scrape the dashboard HTML, and do not try to assemble the board out of `quick_search_sessions` plus a `get_session` per row.

      ## How to rank it

      Highest first:

      1. **Easy decisions that unblock a lot of other work.** A row marked `Mergeable: yes` is a green PR with a Merge button already waiting for a click — if other sessions are plausibly waiting on that PR, it belongs at the very top. A one-click approval that releases a queue beats a long deliberation that releases nothing.
      2. **Anything the human has asked for with stated priority.** The title, the goal and the generated status summary are where that shows up; take it at face value.
      3. **Cheap decisions over expensive ones.** A row whose summary makes the choice obvious in one sentence ranks above one that needs the transcript read.
      4. **Work that is stuck on a person** over work that is stuck on a machine. A session parked holding a PR the merge gate has rated, or one that says it lacked scope or tools, needs a human. A session sleeping on CI does not.
      5. **Failures and anything naming an incident or an alert** rank above ordinary work.

      Rank the tail lowest rather than dropping it: a row you have no opinion about should still be below every row you do.

      ## How to write it back

      Call `reorder_user_view` with `session_ids` top first, and a one-line `reason`. It writes the whole ordering in one transaction and spaces the values so the human can still drag any row afterwards. It is a partial order by design — sessions you do not list keep their own rank, below the ones you do.

      Two things it will not do for you:

      - It does not change a session's scheduling class, and the board draws every `priority` session above every `spot` one. If something genuinely belongs at the very top of a human's attention and is currently `spot`, promote it with `action_session` → `change_scheduling_class` as well, and say in your final message that you did.
      - Precedence is a real scheduling signal, not a display preference: it is the order Zimmer starts spot sessions in. Ranking something to the top of this board also means it gets worked sooner. That is intended — rank accordingly.

      ## When you are done

      Say, in a handful of lines, what you moved to the top and why. Then **archive yourself**. You are this deployment's durable reprioritizer: the next press of the button resumes this same conversation, so anything worth remembering between presses belongs in your session notes rather than in a session left open. Do not park in `needs_input`; nothing here needs a human to answer.
    PROMPT

    Result = Data.define(:session, :outcome, :message) do
      def session? = !session.nil?
    end

    # @return [Result]
    def self.call
      new.call
    end

    def call
      trigger = self.class.trigger!

      fire = Triggers::ManualFire.call(
        trigger: trigger,
        genesis: SessionGenesis::WEB_UI,
        variables: {}
      )

      Result.new(
        session: fire.session,
        outcome: fire.outcome,
        message: message_for(fire)
      )
    end

    # Postgres advisory lock key for the lazy create below. `triggers.name` has no
    # unique index, so two presses landing together would otherwise both insert and
    # the deployment would end up with two reprioritizers reusing two different
    # sessions. A transaction-scoped advisory lock is the cheapest way to make the
    # find-or-create atomic without adding an index and a migration to a table
    # nothing else needs one on. Fixed value, distinct from the three namespaces in
    # Session, Trigger and ClaudeAccount.
    CREATE_ADVISORY_LOCK_KEY = 0x415F_4452 # "A_DR" ASCII — dashboard reprioritizer

    # The durable trigger, created on first use.
    #
    # Lazily rather than from a seed or a post-deploy task: the row has to exist on
    # a fresh install and again after somebody deletes it from /triggers, and a lazy
    # create heals both without anyone needing a shell on the box.
    #
    # @return [Trigger]
    def self.trigger!
      existing = Trigger.find_by(name: TRIGGER_NAME)
      return existing if existing

      Trigger.transaction do
        Trigger.connection.execute("SELECT pg_advisory_xact_lock(#{CREATE_ADVISORY_LOCK_KEY})")
        Trigger.find_by(name: TRIGGER_NAME) || create_trigger!
      end
    end

    def self.create_trigger!
      Trigger.create!(
        name: TRIGGER_NAME,
        status: "disabled",
        agent_root_name: AGENT_ROOT,
        prompt_template: PROMPT_TEMPLATE,
        reuse_session: true,
        # A press that lands while the reprioritizer is mid-turn goes into the
        # durable queue rather than being dropped: the board it was asked about
        # has changed, and it drains at the next turn boundary.
        enqueue_messages: true,
        # It archives itself when it is done, which is exactly the state the next
        # press has to be able to bring it back from.
        resuscitate_archived: true,
        # A human holding the button down must not spawn a fleet.
        max_sessions_per_minute: 2,
        # A human pressed a button and is watching the board for the answer, so
        # this does not queue behind the spot sessions it is ranking.
        scheduling_class: SessionGenesis::PRIORITY,
        trigger_conditions_attributes: [
          {
            condition_type: "schedule",
            # Never fires on its own — the trigger is disabled, and every
            # automatic firing path filters on `status: "enabled"`. A recurring
            # shape rather than a one-time one on purpose; see the class comment.
            configuration: { "interval" => 1, "unit" => "weeks", "day_of_week" => "monday", "time" => "09:00", "timezone" => "UTC" }
          }
        ]
      )
    end

    private

    def message_for(fire)
      case fire.outcome
      when :fired
        if fire.session&.persisted?
          "Reprioritizing — session #{fire.session.id} is re-ranking the board."
        else
          fire.message
        end
      else
        fire.message
      end
    end
  end
end
