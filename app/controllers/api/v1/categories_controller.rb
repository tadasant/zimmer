# API controller for managing organizational categories used to group session
# cards on the dashboard. Mirrors the web CategoriesController so an agent can
# reorganize categories programmatically (list, create, rename/describe, freeze,
# reorder, delete).
#
# All endpoints require API key authentication via X-API-Key header.
class Api::V1::CategoriesController < Api::BaseController
  before_action :set_category, only: [ :update, :destroy ]

  # GET /api/v1/categories
  # List all categories ordered by position, each with its session count.
  def index
    counts = Session.where.not(category_id: nil).group(:category_id).count
    categories = Category.ordered

    render json: {
      categories: categories.map { |c| category_json(c, session_count: counts[c.id] || 0) }
    }
  end

  # POST /api/v1/categories
  # Create a new category.
  #
  # Request body:
  #   - name: Category name (required, unique, max 100 chars)
  #   - description: Optional description (max 1000 chars) used to guide
  #     auto-categorization of new sessions
  def create
    @category = Category.new(name: params[:name], description: params[:description])

    if @category.save
      render json: { category: category_json(@category, session_count: 0) }, status: :created
    else
      render json: { error: "Validation failed", messages: @category.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /api/v1/categories/:id
  # Update a category's name, description, and/or frozen state. A frozen category
  # is a parked bucket excluded from refresh-all and recovery.
  #
  # Request body (any subset):
  #   - name: New name (unique, max 100 chars)
  #   - description: New description (max 1000 chars; blank clears it)
  #   - is_frozen: Boolean freeze/unfreeze flag
  def update
    if @category.update(category_params)
      render json: { category: category_json(@category, session_count: @category.sessions.count) }
    else
      render json: { error: "Validation failed", messages: @category.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/categories/:id
  # Delete a category. Its sessions fall back to "Uncategorized" (category_id is
  # nullified by the association's dependent: :nullify).
  def destroy
    @category.destroy!
    head :no_content
  end

  # POST /api/v1/categories/reorder
  # Persist a new top-to-bottom ordering of the category stack.
  #
  # Request body:
  #   - ids: Ordered array of category ids (top to bottom). Categories omitted
  #     from the list keep their existing position.
  #
  # Returns the categories in their new order.
  def reorder
    Category.reorder!(params[:ids])

    counts = Session.where.not(category_id: nil).group(:category_id).count
    render json: {
      categories: Category.ordered.map { |c| category_json(c, session_count: counts[c.id] || 0) }
    }
  end

  private

  def set_category
    @category = Category.find(params[:id])
  end

  # Permit the editable fields as flat top-level params. Name/description
  # normalization happens in the Category model so the API and web paths stay in
  # sync. Only keys actually present in the request are applied, so a PATCH that
  # sends just is_frozen leaves name and description untouched.
  def category_params
    params.permit(:name, :description, :is_frozen)
  end

  def category_json(category, session_count:)
    {
      id: category.id,
      name: category.name,
      description: category.description,
      position: category.position,
      is_frozen: category.is_frozen,
      session_count: session_count,
      created_at: category.created_at.iso8601,
      updated_at: category.updated_at.iso8601
    }
  end
end
