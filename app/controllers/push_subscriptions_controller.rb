# Controller for managing web push notification subscriptions.
#
# Provides JSON API endpoints for the service worker to register and
# unregister push subscriptions.
#
# All endpoints return JSON responses.
class PushSubscriptionsController < ApplicationController
  # Skip CSRF protection for API-style endpoints called from service worker
  skip_before_action :verify_authenticity_token

  # POST /push_subscriptions
  # Create a new push subscription or update an existing one (upsert by endpoint).
  #
  # Request body (JSON):
  #   - endpoint: Push service URL (required)
  #   - p256dh_key: Public encryption key (required)
  #   - auth_key: Authentication secret (required)
  #   - user_agent: Browser identifier (optional)
  #
  # Returns:
  #   - 201 Created with subscription JSON on success
  #   - 200 OK with subscription JSON if endpoint already exists (updated)
  #   - 422 Unprocessable Entity with error messages on validation failure
  def create
    @subscription = PushSubscription.find_by(endpoint: subscription_params[:endpoint])

    if @subscription
      # Update existing subscription (keys may have changed)
      if @subscription.update(subscription_params)
        render json: subscription_json(@subscription), status: :ok
      else
        render json: { error: "Validation failed", messages: @subscription.errors.full_messages }, status: :unprocessable_entity
      end
    else
      # Create new subscription
      @subscription = PushSubscription.new(subscription_params)

      if @subscription.save
        render json: subscription_json(@subscription), status: :created
      else
        render json: { error: "Validation failed", messages: @subscription.errors.full_messages }, status: :unprocessable_entity
      end
    end
  end

  # DELETE /push_subscriptions/:id
  # Remove a push subscription.
  #
  # Returns:
  #   - 204 No Content on success
  #   - 404 Not Found if subscription doesn't exist
  def destroy
    @subscription = PushSubscription.find(params[:id])
    @subscription.destroy!
    head :no_content
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Not Found", message: "Subscription not found" }, status: :not_found
  end

  private

  def subscription_params
    params.permit(:endpoint, :p256dh_key, :auth_key, :user_agent)
  end

  def subscription_json(subscription)
    {
      id: subscription.id,
      endpoint: subscription.endpoint,
      created_at: subscription.created_at.iso8601,
      updated_at: subscription.updated_at.iso8601
    }
  end
end
