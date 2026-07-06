# frozen_string_literal: true

# API controller for listing available skills from the catalog.
#
# Provides read-only access to skill metadata from the configuration catalog.
# Only exposes non-sensitive fields (id, name, title, description, category).
#
# All endpoints require API key authentication via X-API-Key header.
class Api::V1::SkillsController < Api::BaseController
  # GET /api/v1/skills
  # List all available skills with their metadata.
  #
  # Returns:
  #   - id: Globally unique skill identifier
  #   - name: Machine-readable skill name (used as folder name)
  #   - title: Human-readable display name
  #   - description: Brief description of the skill's purpose
  #   - category: Category grouping (derived from directory structure)
  def index
    skills = SkillsConfig.all.map(&:to_h)

    render json: { skills: skills }
  end
end
