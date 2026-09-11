# frozen_string_literal: true

# The orchestrator's record of one workflow run (#18): which workflow, fired from
# which trigger, with what validated input, resolving to which trusted
# identifiers. One row per session a workflow started, keyed by that session.
#
# `resolved` is why the row exists. It holds what the run is allowed to act on,
# and it comes from exactly one place — the workflow's #plan, before the session
# existed. So it is not in a column anything else writes (Session#metadata is
# written from dozens of places), and it is not in the prompt, which the model
# reads and can be argued out of. The agent may be shown it; nothing the agent
# says can change it.
#
# A run is therefore written once, by Trigger#create_session! on WorkflowRunner's
# behalf, and is read-only from then on: no path updates one, and #readonly?
# makes sure no path can by accident. Removal is the database's job — the
# session foreign key cascades and the trigger one nullifies — so neither a
# session purge nor a trigger cleanup trips over a row that refuses to be touched.
class WorkflowRun < ApplicationRecord
  belongs_to :session
  belongs_to :trigger, optional: true

  validates :workflow_id, presence: true
  validate :input_and_resolved_are_objects

  def readonly?
    persisted? || super
  end

  private

  def input_and_resolved_are_objects
    errors.add(:input, "must be an object") unless input.is_a?(Hash)
    errors.add(:resolved, "must be an object") unless resolved.is_a?(Hash)
  end
end
