class ApplicationController < ActionController::Base
  include ControllerDatabaseRetry

  # Handle 404 errors gracefully
  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found

  private

  def record_not_found
    render file: Rails.public_path.join("404.html"), status: :not_found, layout: false
  end
end
