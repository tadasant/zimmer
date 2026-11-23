# frozen_string_literal: true

# Your board v2's categories, for a client that draws the board itself — the iOS
# app. The rows and the categories are read with `GET /api/v1/sessions?view=board_v2`;
# these are the writes the app makes from that board, each the same model or
# BoardCategories::* call the web UI's BoardCategoriesController and the
# `manage_board_categories` MCP tool make:
#
# * move a session into a category, or back to Uncategorized;
# * collapse or expand a category (stored on the category, so it follows the
#   person between the web and the phone);
# * snooze, backlog or wake a category as a unit.
#
# Creating, renaming, deleting and reordering categories stay on the web UI and
# MCP. Presentation only: nothing here touches status, scheduling or the queue.
class Api::V1::BoardCategoriesController < Api::BaseController
  accepts_native_app_tokens

  include ApiSessionSerialization

  before_action :find_category, only: %i[update visibility]

  # PATCH /api/v1/board_categories/:id — `collapsed` true or false.
  def update
    unless params.key?(:collapsed)
      return render_api_error("Invalid parameter", "Nothing to change: send collapsed.", status: :unprocessable_entity)
    end

    @category.update!(collapsed: ActiveModel::Type::Boolean.new.cast(params[:collapsed]))
    render json: { board_category: board_category_json(@category) }
  end

  # PATCH /api/v1/board_categories/:id/visibility — `visibility` (visible,
  # snoozed or backlogged), `snoozed_until` for a snooze, and `timezone` for a
  # bare local time, as a session's own visibility write takes them.
  def visibility
    BoardCategories::SetVisibility.call(
      category: @category,
      visibility: params[:visibility],
      snoozed_until: params[:snoozed_until],
      timezone: params[:timezone].presence || "UTC"
    )
    render json: { board_category: board_category_json(@category) }
  rescue Sessions::SetVisibility::Error => e
    render_api_error("Invalid parameter", e.message, status: :unprocessable_entity)
  end

  # PATCH /api/v1/sessions/:id/board_category — `board_category_id`, blank or
  # null for Uncategorized. Answers the session, as the other row writes do.
  def assign
    session = Session.locate!(params[:id])
    BoardCategories::Assign.call(session: session, category_id: params[:board_category_id])
    render json: { session: session_json(session) }
  rescue BoardCategories::Assign::Error => e
    render_api_error("Invalid parameter", e.message, status: :unprocessable_entity)
  end

  private

  def find_category
    @category = BoardCategory.find(params[:id])
  end
end
