# frozen_string_literal: true

# Your board v2's categories, from the web UI.
#
# Every action answers JSON for the board_v2 Stimulus controller, which drives
# them with fetch, and HTML (a redirect back to the board) for the forms that
# work without it: create, rename and delete. The writes themselves are the
# model and BoardCategories::*, shared with the `manage_board_categories` MCP
# tool.
class BoardCategoriesController < ApplicationController
  before_action :find_category, only: %i[update destroy visibility]

  # POST /board_categories
  def create
    category = BoardCategory.create!(name: params[:name])
    respond_ok({ id: category.id, name: category.name }, notice: "Created category \"#{category.name}\".")
  rescue ActiveRecord::RecordInvalid => e
    respond_error(e.record.errors.full_messages.to_sentence)
  end

  # PATCH /board_categories/:id — rename, or collapse / expand.
  def update
    attrs = {}
    attrs[:name] = params[:name] if params.key?(:name)
    attrs[:collapsed] = ActiveModel::Type::Boolean.new.cast(params[:collapsed]) if params.key?(:collapsed)
    return respond_error("Nothing to change: send name or collapsed.") if attrs.empty?

    @category.update!(attrs)
    respond_ok({ id: @category.id, name: @category.name, collapsed: @category.collapsed })
  rescue ActiveRecord::RecordInvalid => e
    respond_error(e.record.errors.full_messages.to_sentence)
  end

  # DELETE /board_categories/:id — its sessions fall back to Uncategorized.
  def destroy
    @category.destroy!
    respond_ok({ id: @category.id }, notice: "Deleted category \"#{@category.name}\". Its sessions are in Uncategorized.")
  end

  # PATCH /board_categories/reorder — category_ids, top first.
  def reorder
    ordered = BoardCategories::Reorder.call(ids: params[:category_ids])
    render json: { category_ids: ordered.map(&:id) }
  rescue BoardCategories::Reorder::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # PATCH /board_categories/:id/visibility — snooze or backlog the category as
  # a unit, or put it back. Driven by the shared `visibility` Stimulus
  # controller, which posts the same body it posts for a session.
  def visibility
    BoardCategories::SetVisibility.call(
      category: @category,
      visibility: params[:visibility],
      snoozed_until: params[:snoozed_until],
      timezone: params[:timezone].presence || "UTC"
    )
    render json: { id: @category.id, visibility: @category.visibility, snoozed_until: @category.snoozed_until&.iso8601 }
  rescue Sessions::SetVisibility::Error, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # PATCH /sessions/:id/board_category — the drag of a card into a category.
  # board_category_id blank means Uncategorized.
  def assign
    session = Session.find(params[:id])
    category = BoardCategories::Assign.call(session: session, category_id: params[:board_category_id])
    render json: { id: session.id, board_category_id: category&.id }
  rescue BoardCategories::Assign::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def find_category
    @category = BoardCategory.find(params[:id])
  end

  def board_v2_path
    root_path(view: SessionsController::VIEW_MODE_BOARD_V2)
  end

  def respond_ok(payload, notice: nil)
    respond_to do |format|
      format.json { render json: payload }
      format.html { redirect_to board_v2_path, notice: notice }
    end
  end

  def respond_error(message)
    respond_to do |format|
      format.json { render json: { error: message }, status: :unprocessable_entity }
      format.html { redirect_to board_v2_path, alert: message }
    end
  end
end
