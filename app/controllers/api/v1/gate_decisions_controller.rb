# frozen_string_literal: true

# The REST half of the gate decision ledger. Mirrors the `search_gate_decisions`
# and `record_gate_decision` MCP tools exactly — all four paths go through
# GateDecisions::Filters and GateDecisions::Record, so the two surfaces cannot
# disagree about what a decision is or about which ones match a query.
#
# THERE IS NO FEEDBACK-APPEND ACTION HERE, AND THAT IS THE POINT.
#
# `human_feedback` is the one field in this ledger whose entire value is that a
# machine did not write it. Api::BaseController authenticates an API key that the
# whole agent fleet shares: it establishes a caller, but not a person. So the
# write path for feedback is GateDecisionFeedbacksController — an
# ApplicationController descendant, i.e. the browser, where Zimmer's single
# circle of trust means the request was typed by a human. That is the same rule,
# drawn at the same boundary, that HumanMessageCapture draws for what a human
# said to a session.
#
# There is also no update and no destroy, on either surface. A GateDecision is
# append-only; a correction is a new row.
class Api::V1::GateDecisionsController < Api::BaseController
  # GET /api/v1/gate_decisions
  #
  # Filters: gate, surface, decision, artifact_url, from, to, query,
  # with_human_feedback. Paginated with the standard page/per_page.
  def index
    filters = GateDecisions::Filters.new(filter_params)
    result = paginate(filters.scope.includes(:feedbacks))

    render json: {
      gate_decisions: result[:records].map { |decision| decision_json(decision) },
      pagination: result[:pagination]
    }
  rescue GateDecisions::Filters::InvalidFilter => e
    render_api_error("Invalid filter", e.message, status: :unprocessable_entity)
  end

  # GET /api/v1/gate_decisions/:id
  # The whole row, payload and human feedback included.
  def show
    decision = GateDecision.includes(:feedbacks).find(params[:id])
    render json: { gate_decision: decision_json(decision, include_payload: true) }
  end

  # POST /api/v1/gate_decisions
  #
  # Body:
  #   gate                - "pr_merge" or "issue_work"
  #   surface             - the agent root / repo the gate rated on
  #   entry               - the decision, in whatever shape the gate writes
  #   writing_session_id  - optional; the session recording this
  #
  # `entry["human_feedback"]` is dropped, silently and always. See the class
  # comment: it is not a machine-writable field.
  def create
    result = GateDecisions::Record.call(
      gate: params[:gate],
      surface: params[:surface],
      entry: entry_param,
      recorded_via: GateDecision::API,
      writing_session: writing_session
    )

    render json: { gate_decision: decision_json(result.decision, include_payload: true) }, status: :created
  rescue GateDecisions::Record::InvalidEntry => e
    render_api_error("Invalid gate decision", e.errors, status: :unprocessable_entity)
  end

  private

  # Named explicitly rather than handed the whole params object: an unpermitted
  # ActionController::Parameters cannot be converted to a Hash, and spelling the
  # filters out here keeps the REST surface and the MCP tool's input schema
  # visibly the same list.
  FILTER_KEYS = %i[gate surface decision artifact_url query with_human_feedback from to].freeze

  def filter_params
    params.permit(*FILTER_KEYS).to_h
  end

  # `params[:entry]` arrives as ActionController::Parameters, which is not a Hash
  # and would be rejected as "not a JSON object". `to_unsafe_h` is safe precisely
  # because nothing is mass-assigned from it: GateDecisions::Entry reads the keys
  # it promotes one at a time, and the rest is stored as opaque jsonb.
  def entry_param
    raw = params[:entry]
    raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
  end

  # A writing session that names nothing is dropped rather than failing the write:
  # the decision is the valuable artifact and the provenance link is a nicety.
  # Deliberately NOT trusted as an authorization claim — it records who says they
  # wrote the row, on a surface where the API key already establishes the caller.
  def writing_session
    identifier = params[:writing_session_id]
    return nil if identifier.blank?

    Session.find_by(id: identifier.to_s.to_i) || Session.find_by(slug: identifier.to_s)
  end

  def decision_json(decision, include_payload: false)
    json = {
      id: decision.id,
      gate: decision.gate,
      surface: decision.surface,
      artifact_url: decision.artifact_url,
      title: decision.title,
      decided_at: decision.decided_at&.iso8601,
      decision: decision.decision,
      producing_session_url: decision.producing_session_url,
      writing_session_id: decision.writing_session_id,
      recorded_via: decision.recorded_via,
      recorded_at: decision.created_at.iso8601,
      human_feedback: decision.feedbacks.map { |feedback| feedback_json(feedback) }
    }
    json[:payload] = decision.payload if include_payload
    json
  end

  def feedback_json(feedback)
    {
      id: feedback.id,
      verdict: feedback.verdict,
      note: feedback.note,
      received_at: feedback.received_at&.iso8601,
      author: feedback.author,
      channel: feedback.channel,
      recorded_at: feedback.created_at.iso8601
    }
  end
end
