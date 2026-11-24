# frozen_string_literal: true

# Who is listening to a session's events, held by Zimmer on their behalf.
#
# An agent session is not an MCP Events client: its runtime cannot hold a cursor
# between turns, and it is not running when the event happens. So Zimmer is the
# client for it. A session spawned under a parent is created with its parent's
# subscription (Session#subscribe_parent_to_events), and delivering an event to a
# subscriber is handing it that subscriber's own inbox.
#
# The row exists at most once per (session, subscriber), and records the last
# event it delivered, so "did the parent hear about this" has an answer.
class SessionEventSubscription < ApplicationRecord
  SUBSCRIBER_TYPES = %w[Session].freeze

  belongs_to :session
  belongs_to :subscriber, polymorphic: true

  validates :subscriber_type, inclusion: { in: SUBSCRIBER_TYPES }
  validate :event_names_are_published

  # The parent's subscription to +child+. A session from before subscriptions
  # existed, or one whose parent changed since, gets its row here; the edge
  # itself (`parent_session_id`) decides who the parent is, and a row for an
  # earlier parent goes.
  #
  # @return [SessionEventSubscription, nil] nil when the child has no parent
  def self.for_parent!(child)
    return nil if child.parent_session_id.blank? || child.parent_session_id == child.id

    where(session_id: child.id, subscriber_type: "Session").where.not(subscriber_id: child.parent_session_id).delete_all
    subscribe!(session_id: child.id, subscriber_type: "Session", subscriber_id: child.parent_session_id,
               event_names: [ SessionEvents::MESSAGE ])
  end

  def self.subscribe!(session_id:, subscriber_type:, subscriber_id:, event_names:)
    edge = { session_id: session_id, subscriber_type: subscriber_type, subscriber_id: subscriber_id }
    now = Time.current
    insert_all([ edge.merge(event_names: event_names, created_at: now, updated_at: now) ],
               unique_by: :index_session_event_subscriptions_on_edge)
    find_by!(edge)
  end

  def delivered!(event)
    update_columns(last_event_id: event.event_id, last_event_at: Time.current, updated_at: Time.current)
  end

  private

  def event_names_are_published
    return if event_names.is_a?(Array) && event_names.any? && (event_names - SessionEvents::NAMES).empty?

    errors.add(:event_names, "must be a non-empty list of #{SessionEvents::NAMES.join(', ')}")
  end
end
