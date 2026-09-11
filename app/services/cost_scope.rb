# frozen_string_literal: true

# Which slice of the ledger a Costs view is about: the whole fleet, one agent
# root, or one session.
#
# The parallel of CostWindow, and for the same reason. The window had to become
# an object because every link on the page round-trips it; a narrowed page has
# exactly that problem the moment it exists, and the two have to round-trip
# TOGETHER — clicking a preset while scoped to one root has to keep the root,
# and clicking into a root has to keep the window.
#
# `session_id` wins when both are given, which is what `get_costs` does with the
# same pair of arguments. A session sits inside a root, so the narrower of the
# two is the one the reader actually asked for.
class CostScope
  attr_reader :agent_root, :session_id

  # @param params [ActionController::Parameters, Hash]
  def self.from_params(params)
    new(agent_root: params[:agent_root], session_id: params[:session_id])
  end

  def initialize(agent_root: nil, session_id: nil)
    # Digits only. A hand-typed `?session_id=nope` is a scope nobody asked for,
    # and `"nope".to_i` is 0 — a real id shape that silently narrows the page to
    # a session that cannot exist. Refusing to parse it falls back to the fleet.
    @session_id = session_id.to_s[/\A\d+\z/]&.to_i
    @agent_root = @session_id ? nil : scalar(agent_root)
  end

  def fleet? = @session_id.nil? && @agent_root.nil?
  def session? = !@session_id.nil?
  def agent_root? = !@agent_root.nil?

  # What a link has to carry to keep this scope. Splatted into path helpers
  # alongside CostWindow#to_params.
  def to_params
    return {} if fleet?
    return { session_id: session_id } if session?
    { agent_root: agent_root }
  end

  def label
    return "all agent roots" if fleet?
    return "session ##{session_id}" if session?
    agent_root
  end

  # Narrow a ledger relation to this scope.
  #
  # `session_token_usages` and `token_usage_features` both carry `session_id` and
  # a denormalized `agent_root`, so both narrow the same way — which is what lets
  # the feature split survive a drilldown rather than being dropped from it.
  def narrow(relation)
    return relation if fleet?
    return relation.where(session_id: session_id) if session?

    relation.for_agent_root(agent_root)
  end

  # Ad hoc spend is Zimmer's OWN inference, made outside any session, so it has
  # no agent root to be narrowed by: a root-scoped view of it is empty, not
  # unfiltered. A session-scoped view is neither — `subject_session_id` records
  # the session a generated title or push summary was ABOUT, which is spend that
  # session caused, and it is the same column `GET /api/v1/costs/records` filters
  # on for `kind=adhoc`.
  def narrow_adhoc(relation)
    return relation if fleet?
    return relation.where(subject_session_id: session_id) if session?

    relation.none
  end

  # The part of a cache key that says which slice this is. Without it a scoped
  # page and the fleet page share an entry and one of them serves the other's
  # numbers.
  def cache_token
    return "fleet" if fleet?
    return "session/#{session_id}" if session?

    "root/#{agent_root}"
  end

  private

  # An agent root is a scalar or it is nothing. `?agent_root[]=x` hands the
  # controller an Array and `?agent_root[a]=1` a Parameters, and `to_s` on either
  # produces a plausible-looking string — which would then round-trip through
  # every link on the page, the hidden form field, the banner, and the cache key.
  def scalar(value)
    return nil unless value.is_a?(String) || value.is_a?(Symbol) || value.is_a?(Numeric)

    value.to_s.presence
  end
end
