# frozen_string_literal: true

# Every workflow Zimmer can run (#18), listed by hand.
#
# Explicit rather than self-registering, deliberately. A `Class.inherited` hook
# registers a workflow only once its file has loaded, and under Zeitwerk that
# depends on the environment: production eager-loads every file, while test and
# development load a class on first reference. A registry filled that way is
# complete in production and empty in a test that never happened to name the
# class — the opposite of what a list of "what can run" is for. This constant is
# the list, identical everywhere, and it is the whole answer to what can run.
#
# Same shape as RuntimeRegistry.
module WorkflowRegistry
  # A KeyError, because that is what it is: a lookup by a key nothing registered.
  class UnknownWorkflowError < KeyError; end

  WORKFLOWS = [
    EchoWorkflow
  ].index_by(&:workflow_id).freeze

  # @raise [UnknownWorkflowError] for an id no registered workflow declares
  # @return [Class] the workflow class
  def self.find!(id)
    WORKFLOWS.fetch(id.to_s) { raise UnknownWorkflowError, "No workflow registered with id #{id.inspect}" }
  end

  def self.registered?(id)
    WORKFLOWS.key?(id.to_s)
  end

  # @return [Array<Class>]
  def self.all
    WORKFLOWS.values
  end
end
