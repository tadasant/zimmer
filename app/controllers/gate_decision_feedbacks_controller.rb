# frozen_string_literal: true

# The ONE write path for human feedback on a gate decision.
#
# WHY THIS CONTROLLER EXISTS AT ALL, RATHER THAN AN ACTION ON THE API
#
# Everything else in the gate decision ledger is a machine's account of its own
# reasoning. A feedback row is the record of a *person* overruling a gate, and it
# is the highest-authority signal in the corpus — which is exactly why forging one
# is the attack worth defending against. `PR_MERGE_GATE_NO_SELF_ESCALATION.md`
# puts it plainly: a ledger-shaped write carrying an invented `human_feedback`
# note "would sail through a structural check and never be seen by a human."
#
# So the write is drawn at the browser surface, away from the surfaces an agent is
# handed. This is an ApplicationController descendant. Api::BaseController (and
# McpController with it) authenticates an API key shared by the whole agent fleet:
# it establishes a caller, not a human, so it has no feedback-append action and no
# MCP tool writes here. Same rule, same boundary, same reason as
# WebUiHumanMessageCapture.
#
# BE HONEST ABOUT THE STRENGTH OF THAT. ApplicationController performs no
# authentication at all — the perimeter is the tailnet, and agent sessions run
# inside it. This boundary rules out a write over the shared API key, on the REST
# and MCP surfaces a session is actually offered; it does not rule out an agent
# that goes looking for this route — CSRF enforcement means it would have to fetch
# a token from a Zimmer page first, which is a speed bump, not a boundary. "Human-only" needs a way to tell a person from
# an agent at the web surface, which is the agent-login primitive Zimmer does not
# have yet (#371, #220). Until then `web_ui` means "came in through the browser
# surface", which is weaker, and the channel should be read that way.
#
# The author is resolved from that boundary, never read from the request body.
# There is no update and no destroy: a note cannot be edited into saying
# something else, or deleted to make a gate look better than it was.
#
# The `/gate-decisions` view that will POST here is deliberately not part of this
# change — it is the next phase's work. This action is complete and tested
# without it.
class GateDecisionFeedbacksController < ApplicationController
  # POST /gate_decisions/:gate_decision_id/feedbacks
  def create
    decision = GateDecision.find(params[:gate_decision_id])
    author = User.admin

    # No admin in the roster means Zimmer cannot name the human at this boundary,
    # and an unattributed note on the web_ui channel would be the fabrication this
    # whole design refuses. Recording nothing is the safe direction — the same
    # answer HumanMessageCapture gives when the roster names nobody.
    if author.nil?
      return respond(decision, alert: "No admin user is configured (#{User::ADMIN_ENV_KEY}), so this " \
                                      "note cannot be attributed to a person and was not recorded.")
    end

    feedback = decision.feedbacks.new(
      verdict: params[:verdict].to_s.strip,
      note: params[:note].presence,
      received_at: received_at,
      author: author.key,
      channel: GateDecisionFeedback::WEB_UI
    )

    if feedback.save
      respond(decision, notice: "Feedback recorded on gate decision ##{decision.id}.")
    else
      respond(decision, alert: feedback.errors.full_messages.to_sentence)
    end
  end

  private

  # Defaults to today rather than rejecting a blank: the field records when the
  # human said it, and "when they typed it" is the right answer when they do not
  # say otherwise.
  def received_at
    value = params[:received_at]
    return Date.current if value.blank?

    Date.iso8601(value.to_s.strip)
  rescue ArgumentError, TypeError
    Date.current
  end

  # There is no gate-decisions page yet to go back to, so the fallback is the
  # dashboard. Once the view lands it will be the referrer and this keeps working
  # unchanged.
  def respond(decision, notice: nil, alert: nil)
    respond_to do |format|
      format.html { redirect_back(fallback_location: root_path, notice: notice, alert: alert) }
      format.json do
        if alert
          render json: { error: alert }, status: :unprocessable_entity
        else
          render json: { gate_decision_id: decision.id, message: notice }, status: :created
        end
      end
    end
  end
end
