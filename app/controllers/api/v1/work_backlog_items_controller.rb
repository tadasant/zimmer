# frozen_string_literal: true

# The REST half of the work backlog — the ranked queue of gate-cleared issues.
#
# `index`, `show`, `create` and `pull` mirror the `get_work_backlog`,
# `append_work_backlog_item` and `pull_work_backlog_items` MCP tools exactly:
# all of them go through WorkBacklog::Filters, WorkBacklog::Append and
# WorkBacklog::Pull, so the two surfaces cannot disagree about what is on the
# queue, where a new item lands, or what a pull does.
#
# THE HUMAN-ONLY OPERATIONS LIVE HERE AND NOWHERE ELSE. `start_now`, `pin`,
# `unpin` and `remove` have no MCP counterpart on purpose: hand-placing an item,
# taking one off the queue by judgement, and promoting one to a `priority`
# session are the human's levers over what the fleet works on next, and a queue
# that is read by an unattended job is exactly the place an agent must not be
# able to pull those levers. Phase 2's Issues view is the form in front of these
# actions.
#
# Api::BaseController authenticates an API key the whole fleet shares, so this
# boundary is "not offered to an agent's MCP surface", not "a person typed it" —
# the same caveat GateDecisionsController states, for the same reason.
class Api::V1::WorkBacklogItemsController < Api::BaseController
  before_action :set_item, only: [ :show, :start_now, :pin, :unpin, :remove ]

  # GET /api/v1/work_backlog_items
  #
  # The queue in rank order. Filters: status (default queued; "all" for history),
  # surface, repo, scope_direction, kind, estimated_cost, pinned, key, added_by.
  # Paginated with the standard page/per_page.
  def index
    filters = WorkBacklog::Filters.new(filter_params)
    result = paginate(filters.scope)
    positions = queue_positions(result[:records])

    render json: {
      work_backlog_items: result[:records].map { |item| item.as_api_json.merge(position: positions[item.id]) },
      pagination: result[:pagination],
      counts: counts,
      ranking: { order: "precedence desc, added_at asc, id asc", gap: WorkBacklog::Ranking::GAP,
                 bands: WorkBacklog::Ranking.describe_bands }
    }
  rescue WorkBacklog::Filters::InvalidFilter => e
    render_api_error("Invalid filter", e.message, status: :unprocessable_entity)
  end

  # GET /api/v1/work_backlog_items/:id
  # :id is the row id, or the item's key — the queued row for that key, else the
  # most recent one.
  def show
    render json: { work_backlog_item: item_json(@item) }
  end

  # POST /api/v1/work_backlog_items
  #
  # Append one. Body: key, issue_url, repo, surface, title, kind, scope_direction,
  # estimated_cost, plus ratings / gate_verdict / gate_session / decided_at /
  # notes / prompt (issueless items only), added_by (defaults to "human"),
  # acting_session_id (self-declared, provenance only), and — for a human
  # hand-placing the item on create — pinned: true with a precedence.
  #
  # Idempotent on key among queued items: an existing queued item comes back
  # with 200 and `created: false`.
  def create
    result = WorkBacklog::Append.call(
      item_params.merge("added_by" => params[:added_by].presence || "human"),
      added_via: WorkBacklogItem::API,
      writing_session: acting_session,
      placement: params.permit(:pinned, :precedence).to_h
    )

    render json: {
      work_backlog_item: item_json(result.item),
      created: result.created?,
      position: result.position,
      band_respaced: result.respaced
    }, status: result.created? ? :created : :ok
  rescue WorkBacklog::Append::InvalidItem => e
    render_api_error("Invalid work backlog item", e.errors, status: :unprocessable_entity)
  end

  # POST /api/v1/work_backlog_items/pull
  #
  # The groomer's pull. Body: count (top N) or keys (specific queued items),
  # dead ([{key, reason}] with a mechanical reason), acting_session_id.
  def pull
    result = WorkBacklog::Pull.call(
      count: params[:count],
      keys: params[:keys],
      dead: dead_param,
      acting_session: acting_session,
      removed_by: WorkBacklogItem::API
    )

    render json: {
      started: result.started.map { |s| { work_backlog_item: item_json(s.item), session: session_json(s.session) } },
      removed: result.removed.map { |r| { work_backlog_item: item_json(r.item), reason: r.reason } },
      counts: counts
    }
  rescue WorkBacklog::Pull::InvalidPull, WorkBacklog::Start::NotQueued => e
    render_api_error("Invalid pull", e.message, status: :unprocessable_entity)
  rescue AgentRootsConfig::AgentRootNotFoundError => e
    render_api_error("Cannot spawn", e.message, status: :unprocessable_entity)
  end

  # POST /api/v1/work_backlog_items/:id/start_now
  #
  # The human's promote button: spawn a `priority` zimmer-router session for a
  # queued item right now and mark it started. No MCP counterpart.
  def start_now
    result = WorkBacklog::Start.call(
      item: @item,
      scheduling_class: SessionGenesis::PRIORITY,
      acting_session: acting_session,
      genesis: SessionGenesis::API
    )

    render json: { work_backlog_item: item_json(result.item), session: session_json(result.session) }, status: :created
  rescue WorkBacklog::Start::NotQueued => e
    render_api_error("Not queued", e.message, status: :unprocessable_entity)
  rescue AgentRootsConfig::AgentRootNotFoundError => e
    render_api_error("Cannot spawn", e.message, status: :unprocessable_entity)
  end

  # PATCH /api/v1/work_backlog_items/:id/pin
  # Body: precedence. Hand-place the item and pin it there. No MCP counterpart.
  def pin
    return render_api_error("Not queued", "#{@item.key} is #{@item.status}", status: :unprocessable_entity) unless @item.queued?
    return render_api_error("Missing precedence", "pin needs an integer precedence", status: :unprocessable_entity) if params[:precedence].blank?

    WorkBacklog::Ranking.with_lock do
      @item.pin!(precedence: params[:precedence])
      WorkBacklog::Ranking.rerank!
    end

    render json: { work_backlog_item: item_json(@item.reload) }
  rescue ArgumentError, TypeError => e
    render_api_error("Invalid precedence", e.message, status: :unprocessable_entity)
  end

  # PATCH /api/v1/work_backlog_items/:id/unpin
  # Release a pin; the item is re-ranked back into its cost band.
  def unpin
    return render_api_error("Not queued", "#{@item.key} is #{@item.status}", status: :unprocessable_entity) unless @item.queued?

    WorkBacklog::Ranking.with_lock do
      @item.unpin!
      WorkBacklog::Ranking.rerank!
    end

    render json: { work_backlog_item: item_json(@item.reload) }
  end

  # POST /api/v1/work_backlog_items/:id/remove
  # Body: reason (required, free text), removed_by (defaults to "human").
  # A discretionary removal — the row stays, as history. No MCP counterpart.
  def remove
    return render_api_error("Not queued", "#{@item.key} is #{@item.status}", status: :unprocessable_entity) unless @item.queued?
    return render_api_error("Missing reason", "say why the item is being removed", status: :unprocessable_entity) if params[:reason].blank?

    WorkBacklog::Ranking.with_lock do
      @item.remove!(reason: params[:reason].to_s, by: params[:removed_by].presence || "human")
      WorkBacklog::Ranking.rerank!
    end

    render json: { work_backlog_item: item_json(@item.reload) }
  end

  private

  ITEM_KEYS = %i[key issue_url repo surface title kind scope_direction estimated_cost gate_verdict
                 gate_session decided_at notes prompt].freeze

  # Named explicitly rather than handed the whole params object; `ratings` is a
  # nested object, permitted whole and stored verbatim in `payload`.
  def item_params
    permitted = params.permit(*ITEM_KEYS, ratings: {}).to_h
    permitted["ratings"] = permitted["ratings"].to_h if permitted.key?("ratings")
    permitted
  end

  def filter_params
    params.permit(*WorkBacklog::Filters::KEYS).to_h
  end

  def dead_param
    raw = params[:dead]
    return [] if raw.blank?

    Array(raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw).map { |d| d.respond_to?(:to_unsafe_h) ? d.to_unsafe_h : d }
  end

  # SELF-DECLARED, unlike on the MCP surface. An HTTP request carries no session
  # identity — the API key is shared by the whole fleet — so `acting_session_id`
  # is a claim the caller makes, exactly like elsewhere in this API. Provenance,
  # never authorization. A stale id is dropped rather than failing the write.
  def acting_session
    identifier = params[:acting_session_id].to_s
    return nil if identifier.blank?

    identifier.match?(/\A\d+\z/) ? Session.find_by(id: identifier.to_i) : Session.find_by(slug: identifier)
  end

  def set_item
    identifier = params[:id].to_s
    @item = if identifier.match?(/\A\d+\z/)
      WorkBacklogItem.find_by(id: identifier.to_i)
    else
      WorkBacklogItem.queued.find_by(key: identifier) || WorkBacklogItem.where(key: identifier).order(id: :desc).first
    end

    render_api_error("Not Found", "No work backlog item matches #{identifier.inspect}", status: :not_found) unless @item
  end

  def counts
    {
      queued: WorkBacklogItem.queued.count,
      started: WorkBacklogItem.started.count,
      removed: WorkBacklogItem.removed.count,
      in_flight: WorkBacklogItem.in_flight.count,
      pinned: WorkBacklogItem.queued.pinned_items.count
    }
  end

  def queue_positions(items)
    queued = items.select(&:queued?)
    return {} if queued.empty?

    ranked = WorkBacklogItem.queued.in_rank_order.pluck(:id)
    queued.to_h { |item| [ item.id, ranked.index(item.id)&.succ ] }
  end

  def item_json(item)
    item.as_api_json.merge(position: WorkBacklog::Append.position_of(item))
  end

  def session_json(session)
    {
      id: session.id,
      url: "#{request.base_url}/sessions/#{session.id}",
      title: session.title,
      status: session.status,
      scheduling_class: session.scheduling_class,
      precedence: session.precedence,
      parent_session_id: session.parent_session_id
    }
  end
end
