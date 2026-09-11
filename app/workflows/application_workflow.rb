# frozen_string_literal: true

# The base class every workflow inherits from (#18). A workflow is the
# deterministic shell around a nondeterministic agent run: a stable id a trigger
# points at, a strict input contract, a declaration of what its sessions need,
# and a #plan that turns validated input into the two things a run starts from —
# `resolved`, the trusted identifiers, and `instructions`, the seed prompt.
#
#   class EchoWorkflow < ApplicationWorkflow
#     workflow_id "echo"
#     title       "Echo"
#     description "Restate a message."
#
#     param :message, :text, required: true
#
#     def plan(input)
#       Workflow::Plan.new(resolved: {}, instructions: "Restate: #{input.message}")
#     end
#   end
#
# Plain classes over a thin base, and the only declarative sugar is `param`:
# #plan is ordinary Ruby, because every real workflow will need to branch and look
# things up. A workflow is never stored in the database and never discovered at
# runtime — WorkflowRegistry lists every one by hand.
#
# The human-readable label is `title`, not `name`. `name` is Module#name, and
# overriding it on a class breaks every error message, log line and autoloader
# lookup that asks the class what it is called.
class ApplicationWorkflow
  # Dotted lower-snake segments: "echo", "slack.triage_mention". The id is what a
  # trigger row stores, so it is opaque and permanent — renaming or retitling the
  # class must not orphan the triggers that point at it.
  ID_FORMAT = /\A[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*\z/

  class << self
    # Declare the workflow's stable id (with an argument) or read it (without).
    # Declared once: a second declaration raises rather than re-pointing it.
    def workflow_id(id = nil)
      return @workflow_id if id.nil?

      raise ArgumentError, "#{name} already declares workflow id #{@workflow_id.inspect}" if @workflow_id
      raise ArgumentError, "#{name}: workflow id #{id.inspect} must match #{ID_FORMAT.inspect}" unless ID_FORMAT.match?(id.to_s)

      @workflow_id = id.to_s.freeze
    end

    def title(value = nil)
      return @title if value.nil?

      @title = value.to_s.freeze
    end

    def description(value = nil)
      return @description if value.nil?

      @description = value.to_s.freeze
    end

    # The declared params, in declaration order.
    #
    # @return [Array<Workflow::Param>]
    def params
      @params ||= []
    end

    # Declare one input. The declaration is a descriptor first — label, help,
    # widget, example and options are what a param form will be rendered from —
    # and the validation rule is derived from it, not the other way round.
    def param(key, type, required: false, label: nil, help: nil, widget: nil, example: nil, options: nil)
      key = key.to_sym
      raise ArgumentError, "#{name}: param #{key.inspect} has unknown type #{type.inspect}" unless Workflow::Input::TYPES.key?(type)
      raise ArgumentError, "#{name}: param #{key.inspect} is declared twice" if params.any? { |param| param.key == key }

      params << Workflow::Param.new(
        key: key, type: type, required: required, label: label || key.to_s.humanize,
        help: help, widget: widget, example: example, options: options&.freeze
      )
      input_class.attribute(key, Workflow::Input::TYPES.fetch(type))
    end

    # Declare what a run needs: its agent root, and the MCP servers, skills and
    # goal a session running it is equipped with. Catalog names, not credentials —
    # the orchestrator resolves them at spawn the same way it resolves a
    # trigger's own columns. test/workflows/workflow_catalog_references_test.rb
    # fails the build on any name the catalog cannot resolve.
    def requires(agent_root: nil, mcp_servers: [], skills: [], goal: nil)
      @requirements = Workflow::Requirements.new(agent_root: agent_root, mcp_servers: mcp_servers, skills: skills, goal: goal)
    end

    # @return [Workflow::Requirements]
    def requirements
      @requirements ||= Workflow::Requirements.new
    end

    # The ActiveModel class a payload is validated as — one per workflow,
    # generated from its `param` declarations.
    def input_class
      @input_class ||= Class.new(Workflow::Input).tap { |klass| klass.workflow = self }
    end

    # Validate an untrusted payload. This is the boundary: nothing downstream —
    # #plan, the session, the run record — ever sees a payload that did not pass.
    #
    # @raise [Workflow::Input::InvalidInputError]
    # @return [Workflow::Input]
    def build_input!(payload)
      input = input_class.new(payload)
      raise Workflow::Input::InvalidInputError.new(input) unless input.valid?

      input
    end
  end

  # Turn validated input into a Workflow::Plan.
  #
  # May look things up — resolving a user id to a name, say — but must not cause
  # a side effect, and must raise rather than guess when a lookup fails. It runs
  # before the session exists, so raising is how a run fails closed.
  #
  # @param input [Workflow::Input]
  # @return [Workflow::Plan]
  def plan(input)
    raise NotImplementedError, "#{self.class.name} must implement #plan"
  end
end
