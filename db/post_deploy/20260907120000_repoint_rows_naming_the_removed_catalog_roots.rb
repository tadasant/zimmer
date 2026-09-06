# frozen_string_literal: true

# Repoints the rows that name `agent-orchestrator` or `agents` — the two agent
# roots https://github.com/tadasant/zimmer/issues/67 removed from `roots.json` —
# at `zimmer`, the root they were duplicates of.
#
# THE POINT OF THIS FILE: removing a root from the catalog is subtractive, and
# `Trigger#heal_stale_agent_root!` is the thing that normally absorbs it. It
# cannot absorb this one. Healing looks for a successor by matching the last
# session's `(git_root, subdirectory)` against the catalog, and every session
# under these two roots carries `https://github.com/tadasant/zimmer-catalog.git`
# — a URL no root points at any more, precisely because that repository does not
# exist. So `find_agent_root_successor` returns nil and the `elsif
# raise_when_unhealable` branch raises `AgentRootNotFoundError` on EVERY fire of
# such a trigger: `.error`, which pages #alerts, on a schedule, indefinitely.
#
# The same removal blanks the "Root:" row on those sessions' detail pages and
# drops them out of the dashboard's agent-root filter, because
# `AgentRootsConfig#find_for_session` resolves the stale key to nil and its
# `(url, subdirectory)` fallback finds no match either. That half is cosmetic;
# the paging is not.
#
# It ships with the deploy because AGENTS.md ("ops actions ship with the deploy")
# leaves no other route — nobody has a shell on the production box, and the
# per-trigger Re-arm button on /triggers needs a human who already knows which
# rows to look at and why. What it did is a row in `post_deploy_task_runs` — on
# /health, in `GET /api/v1/health`, from `get_system_health`, and at
# /supervisor/post_deploy_task_runs — rather than somebody's recollection.
#
# WHY `zimmer` IS THE RIGHT SUCCESSOR. Both removed roots were `zimmer` under
# other names. `agent-orchestrator` described itself as "The Zimmer orchestrator
# Rails app itself" and carried `zimmer`'s `display_name` and `default_goal`
# verbatim — it is the pre-rename name, and the source of the duplicate display
# name #67 also fixed. `agents` described the harness artifacts that, now the
# catalog is self-contained, sit at the root of this repo. Both denote the code
# `zimmer` denotes, so this is a rename applied backwards, not a reassignment.
#
# WHAT IT DELIBERATELY DOES NOT TOUCH: `sessions.git_root` and
# `sessions.subdirectory`. Those still name `tadasant/zimmer-catalog` on the
# affected rows, and rewriting a historical session's clone coordinates would
# claim it ran somewhere it did not. Unarchiving one would fail to clone — but it
# would have failed identically before #67, since that repository does not exist,
# so that is neither this task's regression nor its job to invent a fix for.
#
# IDEMPOTENT. Both updates are conditional on the OLD value, so a row this task
# has repointed no longer matches and a second run finds nothing; a slice that
# died halfway resumes from its cursor with nothing to redo.
#
# ONE SWEEP, NOT TWO. `PostDeployTask#sweep` keys its cursor on `sweep_last_id`
# alone, so two sweeps in one `up` would share a cursor and the second would
# resume from the first's high-water mark, silently skipping rows. The sessions
# side gets the sweep because `sessions` is the large table and
# `index_sessions_on_agent_root_key` serves its predicate, keeping even the tail
# query cheap. `triggers` is small and is repointed in one bounded pass first.
class RepointRowsNamingTheRemovedCatalogRoots < PostDeployTask
  REMOVED_ROOTS = %w[agent-orchestrator agents].freeze
  SUCCESSOR_ROOT = "zimmer"

  def self.stale_triggers
    Trigger.where(agent_root_name: REMOVED_ROOTS).order(:id)
  end

  def self.stale_sessions
    Session.where("metadata->>'agent_root_key' IN (?)", REMOVED_ROOTS).order(:id)
  end

  def up
    triggers = repoint_triggers
    sessions = stats["sessions"].to_i

    outcome = sweep(self.class.stale_sessions, batch_size: 200) do |batch|
      batch.each do |session|
        session.update_column(:metadata, session.metadata.merge("agent_root_key" => SUCCESSOR_ROOT))
        sessions += 1
      end

      checkpoint!(triggers: triggers, sessions: sessions)
    end

    checkpoint!(triggers: triggers, sessions: sessions)
    outcome
  end

  private

  # Unsliced: `triggers` holds hundreds of rows, not millions, and the ones this
  # matches are the handful armed against a root that could never clone.
  def repoint_triggers
    repointed = stats["triggers"].to_i

    self.class.stale_triggers.each do |trigger|
      was = trigger.agent_root_name
      # update_column, which is what heal_stale_agent_root! itself uses for this
      # same repoint: running a trigger's validations and callbacks on rows
      # nobody has looked at is a bigger act than swapping a name needs.
      trigger.update_column(:agent_root_name, SUCCESSOR_ROOT)
      repointed += 1
      logger.info(
        "[RepointRowsNamingTheRemovedCatalogRoots] trigger #{trigger.id} " \
        "(#{trigger.name}) repointed from #{was} to #{SUCCESSOR_ROOT}"
      )
    end

    repointed
  end
end
