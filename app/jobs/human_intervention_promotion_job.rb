# frozen_string_literal: true

# Moves a spot session to the head of the queue when a named human speaks to it,
# and sends the least human-involved queued session to the bottom in exchange.
#
# == Why a job rather than the callback itself
#
# HumanMessage's `after_create_commit` is the only place that knows a human just
# spoke to a session, so it is where this has to start. It is not where it should
# HAPPEN: the work is a queue read, a placement write, a Sessions::StartNow that
# reaches into GoodJob's own tables, and a second write on a different session —
# several hundred milliseconds on the request that was delivering the human's
# message. Doing it inline would put all of that in front of the thing the person
# was actually waiting for, and a failure in the re-ranking would surface as a
# failed follow-up.
#
# On the `default` queue rather than `agents`: this takes no agent turn of its
# own, and the `agents` lane is the one whose depth the fleet cap is about.
class HumanInterventionPromotionJob < ApplicationJob
  queue_as :default

  # @param human_message_id [Integer]
  def perform(human_message_id)
    message = HumanMessage.find_by(id: human_message_id)
    # The session (and its messages with it) can be archived and trashed between
    # the commit and this job. Nothing to promote is a normal outcome, not an
    # error worth retrying.
    return if message.nil?

    Sessions::HumanInterventionPromotion.call(message)
  end
end
