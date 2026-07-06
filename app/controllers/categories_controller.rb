# Manages organizational categories used to group session cards on the dashboard.
class CategoriesController < ApplicationController
  # Create a new category from a name (prompted for via the "+" button on the
  # dashboard divider). Responds with a Turbo Stream that appends the new, empty
  # category section so it becomes an immediate drop target without a full reload.
  def create
    @category = Category.new(name: params[:name])

    if @category.save
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.append(
            "category_sections",
            partial: "sessions/category_section",
            # A paginatable empty relation, not a bare [], so the section matches the
            # contract #index gives the partial: `sessions` is always a Kaminari
            # collection, so `sessions.total_count` (the header count badge) resolves
            # to 0 here instead of raising NoMethodError on Array.
            locals: { category: @category, sessions: Session.none.page(1) }
          )
        end
        format.json { render json: { success: true, id: @category.id, name: @category.name }, status: :created }
        format.html { redirect_back fallback_location: root_path, notice: "Category \"#{@category.name}\" created" }
      end
    else
      error = @category.errors.full_messages.to_sentence
      respond_to do |format|
        # The "+" button posts with a Turbo Stream Accept header, so a failure must
        # answer that format too — otherwise Rails returns 406 with an empty body and
        # the client surfaces a JSON-parse error instead of the real validation
        # message (e.g. "Name has already been taken").
        format.turbo_stream { render json: { error: error }, status: :unprocessable_entity }
        format.json { render json: { error: error }, status: :unprocessable_entity }
        format.html { redirect_back fallback_location: root_path, alert: error }
      end
    end
  end

  # Update a category's name, description and/or frozen flag from the Edit modal. The
  # dashboard renders the name and a frozen indicator, so a successful JSON response
  # echoes those fields and the client patches the section header in place (no full
  # section re-render that would disrupt the drag-and-drop grid).
  def update
    @category = Category.find(params[:id])

    if @category.update(category_params)
      respond_to do |format|
        format.json { render json: { success: true, id: @category.id, name: @category.name, description: @category.description, is_frozen: @category.is_frozen } }
        format.html { redirect_back fallback_location: root_path, notice: "Category \"#{@category.name}\" updated" }
      end
    else
      error = @category.errors.full_messages.to_sentence
      respond_to do |format|
        format.json { render json: { error: error }, status: :unprocessable_entity }
        format.html { redirect_back fallback_location: root_path, alert: error }
      end
    end
  end

  # Persist a reordering of the whole category stack. The client (drag-and-drop or
  # the right-click "move" menu) sends the new top-to-bottom order of section ids,
  # including the "uncategorized" sentinel. The shared Category.reorder! rewrites
  # each category's +position+ (and AppSetting#uncategorized_position for the
  # sentinel) so the web and REST API paths stay in sync.
  def reorder
    Category.reorder!(params[:ids])

    head :no_content
  end

  # Delete a category. Its sessions fall back to "Uncategorized" (category_id is
  # nullified by the association's dependent: :nullify).
  def destroy
    @category = Category.find(params[:id])
    # Capture the cards before destroy nullifies them so the Turbo Stream can move
    # them into the Uncategorized grid rather than letting them vanish with the
    # removed section.
    orphaned_sessions = @category.sessions.order(favorited: :desc, created_at: :desc).to_a
    @category.destroy

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.remove(helpers.dom_id(@category)),
          *orphaned_sessions.map do |session|
            turbo_stream.append("sessions_grid", partial: "sessions/session_card_frame", locals: { agent_session: session })
          end
        ]
      end
      format.json { render json: { success: true } }
      format.html { redirect_back fallback_location: root_path, notice: "Category deleted" }
    end
  end

  private

  # Permit the editable fields. Name trimming and blank-description-to-NULL
  # normalization happen in the Category model so every write path stays in sync.
  def category_params
    params.require(:category).permit(:name, :description, :is_frozen)
  end
end
