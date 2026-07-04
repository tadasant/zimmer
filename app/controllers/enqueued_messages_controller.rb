# Manages enqueued messages for agent sessions.
#
# Note on authorization: This application is designed as a single-user internal tool
# for orchestrating AI agents locally. There is no multi-user authentication system.
# If this application is deployed in a multi-user environment, authentication and
# authorization must be added via before_action callbacks.
class EnqueuedMessagesController < ApplicationController
  include PendingMessageDelivery
  include ActionView::RecordIdentifier

  before_action :find_session
  before_action :find_enqueued_message, only: [ :destroy, :reorder, :interrupt, :update ]

  # POST /sessions/:session_id/enqueued_messages
  # Creates a new enqueued message for the session
  # Accepts content via :content or :follow_up_prompt params (for form reuse)
  def create
    content = (params[:content] || params[:follow_up_prompt]).to_s.strip
    goal = params[:goal].to_s.strip.presence

    # Validate content
    if content.blank?
      respond_to do |format|
        format.turbo_stream do
          # Replace the entire form to reset button state, plus show errors
          render turbo_stream: [
            turbo_stream.replace(
              "session_#{@session.id}_follow_up_form",
              partial: "sessions/follow_up_form",
              locals: { agent_session: @session }
            ),
            turbo_stream.update(
              "enqueued_messages_form_errors",
              partial: "enqueued_messages/form_errors",
              locals: { errors: [ "Message content cannot be empty" ] }
            )
          ]
        end
        format.html do
          redirect_to @session, alert: "Message content cannot be empty"
        end
      end
      return
    end

    if content.length > Session::PROMPT_MAX_LENGTH
      respond_to do |format|
        format.turbo_stream do
          # Replace the entire form to reset button state, plus show errors
          render turbo_stream: [
            turbo_stream.replace(
              "session_#{@session.id}_follow_up_form",
              partial: "sessions/follow_up_form",
              locals: { agent_session: @session }
            ),
            turbo_stream.update(
              "enqueued_messages_form_errors",
              partial: "enqueued_messages/form_errors",
              locals: { errors: [ "Message is too long (maximum #{Session::PROMPT_MAX_LENGTH.to_fs(:delimited)} characters)" ] }
            )
          ]
        end
        format.html do
          redirect_to @session, alert: "Message is too long (maximum #{Session::PROMPT_MAX_LENGTH.to_fs(:delimited)} characters)"
        end
      end
      return
    end

    # Validate goal length if present
    if goal.present? && goal.length > Session::GOAL_MAX_LENGTH
      respond_to do |format|
        format.turbo_stream do
          # Replace the entire form to reset button state, plus show errors
          render turbo_stream: [
            turbo_stream.replace(
              "session_#{@session.id}_follow_up_form",
              partial: "sessions/follow_up_form",
              locals: { agent_session: @session }
            ),
            turbo_stream.update(
              "enqueued_messages_form_errors",
              partial: "enqueued_messages/form_errors",
              locals: { errors: [ "Goal is too long (maximum #{Session::GOAL_MAX_LENGTH.to_fs(:delimited)} characters)" ] }
            )
          ]
        end
        format.html do
          redirect_to @session, alert: "Goal is too long (maximum #{Session::GOAL_MAX_LENGTH.to_fs(:delimited)} characters)"
        end
      end
      return
    end

    # Calculate next position
    max_position = @session.enqueued_messages.maximum(:position) || 0
    next_position = max_position + 1

    # Parse attachments (images/files) from the form. These are passed as JSON
    # arrays of metadata objects pointing at session-scoped storage paths populated
    # by the upload_images/upload_files endpoints. We persist the metadata so the
    # enqueued message processor can deliver them when the message runs.
    attached_images = parse_enqueued_images
    attached_files = parse_enqueued_files

    result = with_db_retry do
      @enqueued_message = @session.enqueued_messages.create!(
        content: content,
        goal: goal,
        position: next_position,
        status: "pending",
        images: attached_images || [],
        files: attached_files || []
      )

      @session.logs.create!(
        content: "Enqueued message added at position #{next_position}",
        level: "info"
      )

      # Stamps user activity so PollBackoff resets the GitHub-poll cadence
      # for this session.
      @session.touch_user_activity!
    end

    # Check if we already redirected (max retries exceeded)
    return if performed?

    if result != false
      respond_to do |format|
        format.turbo_stream do
          # Replace the entire enqueued messages section and the full follow-up form
          # Replacing the entire form ensures:
          # 1. Button state is reset from server-rendered HTML (no stale "Queueing..." state)
          # 2. Textarea is cleared
          # 3. All Stimulus controllers are re-initialized with fresh state
          render turbo_stream: [
            turbo_stream.replace(
              "session_#{@session.id}_enqueued_messages",
              partial: "enqueued_messages/enqueued_messages_list",
              locals: { agent_session: @session }
            ),
            turbo_stream.replace(
              "session_#{@session.id}_follow_up_form",
              partial: "sessions/follow_up_form",
              locals: { agent_session: @session }
            )
          ]
        end
        format.html do
          redirect_to @session, notice: "Message enqueued successfully"
        end
      end
    end
  end

  # DELETE /sessions/:session_id/enqueued_messages/:id
  # Deletes an enqueued message and re-numbers remaining positions
  def destroy
    result = with_db_retry do
      ActiveRecord::Base.transaction do
        position = @enqueued_message.position

        # Delete the message
        @enqueued_message.destroy!

        # Re-number remaining messages with higher positions
        @session.enqueued_messages
                .where("position > ?", position)
                .update_all("position = position - 1")

        @session.logs.create!(
          content: "Enqueued message at position #{position} removed",
          level: "info"
        )
      end
    end

    # Check if we already redirected (max retries exceeded)
    return if performed?

    if result != false
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "session_#{@session.id}_enqueued_messages",
            partial: "enqueued_messages/enqueued_messages_list",
            locals: { agent_session: @session }
          )
        end
        format.html do
          redirect_to @session, notice: "Message removed successfully"
        end
      end
    end
  end

  # PATCH /sessions/:session_id/enqueued_messages/:id
  # Updates an enqueued message's content and/or goal
  def update
    content = params[:content].to_s.strip
    goal = params[:goal].to_s.strip.presence

    # Validate content
    if content.blank?
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            dom_id(@enqueued_message),
            partial: "enqueued_messages/enqueued_message",
            locals: { message: @enqueued_message, error: "Message content cannot be empty" }
          )
        end
        format.html do
          redirect_to @session, alert: "Message content cannot be empty"
        end
      end
      return
    end

    if content.length > Session::PROMPT_MAX_LENGTH
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            dom_id(@enqueued_message),
            partial: "enqueued_messages/enqueued_message",
            locals: { message: @enqueued_message, error: "Message is too long (maximum #{Session::PROMPT_MAX_LENGTH.to_fs(:delimited)} characters)" }
          )
        end
        format.html do
          redirect_to @session, alert: "Message is too long (maximum #{Session::PROMPT_MAX_LENGTH.to_fs(:delimited)} characters)"
        end
      end
      return
    end

    # Validate goal length if present
    if goal.present? && goal.length > Session::GOAL_MAX_LENGTH
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            dom_id(@enqueued_message),
            partial: "enqueued_messages/enqueued_message",
            locals: { message: @enqueued_message, error: "Goal is too long (maximum #{Session::GOAL_MAX_LENGTH.to_fs(:delimited)} characters)" }
          )
        end
        format.html do
          redirect_to @session, alert: "Goal is too long (maximum #{Session::GOAL_MAX_LENGTH.to_fs(:delimited)} characters)"
        end
      end
      return
    end

    result = with_db_retry do
      @enqueued_message.update!(content: content, goal: goal)

      @session.logs.create!(
        content: "Enqueued message at position #{@enqueued_message.position} updated",
        level: "info"
      )
    end

    # Check if we already redirected (max retries exceeded)
    return if performed?

    if result != false
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            dom_id(@enqueued_message),
            partial: "enqueued_messages/enqueued_message",
            locals: { message: @enqueued_message }
          )
        end
        format.html do
          redirect_to @session, notice: "Message updated successfully"
        end
      end
    end
  end

  # PATCH /sessions/:session_id/enqueued_messages/:id/reorder
  # Reorders the message to a new position
  def reorder
    new_position = params[:position].to_i

    if new_position < 1
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "session_#{@session.id}_enqueued_messages",
            partial: "enqueued_messages/enqueued_messages_list",
            locals: { agent_session: @session }
          )
        end
        format.html do
          redirect_to @session, alert: "Invalid position"
        end
      end
      return
    end

    result = with_db_retry do
      ActiveRecord::Base.transaction do
        old_position = @enqueued_message.position
        @enqueued_message.reorder_to(new_position)

        @session.logs.create!(
          content: "Enqueued message moved from position #{old_position} to #{new_position}",
          level: "info"
        )
      end
    end

    # Check if we already redirected (max retries exceeded)
    return if performed?

    if result != false
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "session_#{@session.id}_enqueued_messages",
            partial: "enqueued_messages/enqueued_messages_list",
            locals: { agent_session: @session }
          )
        end
        format.html do
          redirect_to @session, notice: "Message reordered successfully"
        end
      end
    end
  end

  # POST /sessions/:session_id/enqueued_messages/:id/interrupt
  # Sends the enqueued message immediately, interrupting the running session if needed.
  #
  # Race correctness lives in Sessions::InterruptService — this action only
  # handles HTTP concerns (param parsing, response rendering). The service
  # holds the per-session advisory lock and treats the EnqueuedMessage row
  # itself as the durable queue, ensuring concurrent interrupts on the same
  # session deliver messages exactly once in FIFO order.
  def interrupt
    # Wait for any pending follow-up message to be delivered before we hand
    # off to the service. This preserves the existing behavior where clicking
    # "Send Now" right after a follow-up doesn't drop the follow-up. The
    # service itself does NOT need this wait — it only protects the *previous*
    # follow-up that's racing with the click; once we know the follow-up
    # landed in the transcript we can safely hand off.
    wait_for_pending_message_delivery(@session) if @session.running?

    result = Sessions::InterruptService.new(
      session: @session,
      enqueued_message: @enqueued_message,
      actor: "web"
    ).call

    # Clicking "send now" is direct user engagement; reset PollBackoff cadence.
    @session.touch_user_activity! if result.success?

    if result.success?
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "session_#{@session.id}_enqueued_messages",
            partial: "enqueued_messages/enqueued_messages_list",
            locals: { agent_session: @session.reload }
          )
        end
        format.html do
          redirect_to @session, notice: "Message sent as interrupt. Agent is processing..."
        end
      end
    else
      redirect_to @session, alert: result.error || "Failed to send interrupt"
    end
  end

  private

  def find_session
    param = params[:session_id]
    # If param contains only digits, treat as ID
    if param.match?(/\A\d+\z/)
      @session = Session.find(param)
    else
      # Otherwise, try to find by slug first, fall back to ID
      @session = Session.find_by(slug: param) || Session.find(param)
    end
  end

  def find_enqueued_message
    @enqueued_message = @session.enqueued_messages.find(params[:id])
  end

  # Parse the `images` JSON payload submitted with the follow-up form into the
  # canonical { path:, media_type: } hashes we persist on the EnqueuedMessage.
  # Validates that each referenced image still exists in session-scoped storage.
  def parse_enqueued_images
    return nil unless params[:images].present?

    raw = params[:images].is_a?(String) ? JSON.parse(params[:images]) : params[:images].to_a
    return nil if raw.empty?

    storage = ImageStorageService.new(session_id: @session.id)
    raw.filter_map do |img|
      path = img["path"] || img[:path]
      media_type = img["media_type"] || img[:media_type]
      next unless path.present? && media_type.present?
      next unless storage.exists?(path)

      { "path" => path, "media_type" => media_type }
    end.presence
  rescue JSON::ParserError => e
    Rails.logger.warn "Failed to parse enqueued message images: #{e.message}"
    nil
  end

  # Parse the `files_payload` JSON payload submitted with the follow-up form into
  # the canonical { path:, original_filename:, size: } hashes we persist on the
  # EnqueuedMessage. Validates that each referenced file still exists.
  def parse_enqueued_files
    return nil unless params[:files_payload].present?

    raw = params[:files_payload].is_a?(String) ? JSON.parse(params[:files_payload]) : params[:files_payload].to_a
    return nil if raw.empty?

    storage = FileStorageService.new(session_id: @session.id)
    raw.filter_map do |f|
      path = f["path"] || f[:path]
      original_filename = f["original_filename"] || f[:original_filename]
      size = f["size"] || f[:size]
      next unless path.present? && original_filename.present?
      next unless storage.exists?(path)

      { "path" => path, "original_filename" => original_filename, "size" => size }
    end.presence
  rescue JSON::ParserError => e
    Rails.logger.warn "Failed to parse enqueued message files: #{e.message}"
    nil
  end
end
