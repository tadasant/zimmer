# frozen_string_literal: true

# Delivering a notice or an alert from an action that answers a Turbo request
# with a stream instead of a redirect.
#
# The layout renders exactly one `#flash` container (`shared/_flash`). A redirect
# fills it on the next page load; a Turbo Stream response has no next page load,
# so it has to replace that container itself — without it the message is simply
# not shown, which is how the Undo affordance once went missing.
#
# The message is never written to the real `flash`, so it does not also reappear
# on the following full page load.
module TurboFlash
  extend ActiveSupport::Concern

  private

  def flash_stream(notice: nil, alert: nil)
    messages = {}
    messages["notice"] = notice if notice.present?
    messages["alert"] = alert if alert.present?

    turbo_stream.replace("flash", partial: "shared/flash", locals: { messages: messages })
  end

  # The Turbo half applies `streams` in place and adds the flash; the HTML half
  # redirects and lets the redirect carry it. Non-Turbo clients — and the
  # controller tests that assert on them — keep the redirect they always had.
  #
  # The dashboard's mutating actions used to redirect purely to carry a flash:
  # every card they touch already re-renders itself over the
  # `sessions_index_individual` and `session_<id>_status` broadcast channels, so
  # the round trip through a full page render was the only reason the UI blinked.
  def respond_with_flash(location:, notice: nil, alert: nil, streams: [])
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: streams + [ flash_stream(notice: notice, alert: alert) ]
      end
      format.html do
        redirect_to location, notice: notice, alert: alert
      end
    end
  end
end
