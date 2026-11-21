# frozen_string_literal: true

# A human's merge approval, signed by the Zimmer that heard it and verified by
# the Zimmer that holds the pull request. See MergeAttestations for the
# contract and the threat model.
#
# Two directions, one shape:
#
# * `issued` — this Zimmer heard a person say yes (Live Mode's
#   `authorize_merge`) to a pull request a session on ANOTHER Zimmer holds, and
#   signed an approval for it. `session` is the local session that drives the
#   remote one; `human_message` is the person's yes, recorded there.
# * `received` — another Zimmer's signed approval arrived here, verified, and
#   was handed to the session holding the PR. `session` is that session;
#   `human_message` is the `attested` record written on it.
#
# What a row says about the approval (who, what PR, which commit, the words
# read back and the answer) never changes once written. The delivery columns
# (`outcome`, `outcome_detail`, `remote_session_url`) are the only ones an
# update may touch, because an issuer learns how delivery went after it signs,
# plus `human_message` once, from empty.
class MergeAttestation < ApplicationRecord
  ISSUED = "issued"
  RECEIVED = "received"
  DIRECTIONS = [ ISSUED, RECEIVED ].freeze

  # Issued: `delivered` (the receiver accepted it), `delivery_failed` (the
  # receiver refused it or could not be reached; the reason is in
  # `outcome_detail`). Received: `accepted` (the holding session was told to
  # merge), `undeliverable` (verified, but the session could not take the
  # message). A received row is written only once a token has verified, so a
  # forged one leaves no row, only a log line.
  OUTCOMES = %w[delivered delivery_failed accepted undeliverable].freeze

  MUTABLE_ATTRIBUTES = %w[outcome outcome_detail remote_session_url updated_at].freeze

  belongs_to :session, optional: true
  belongs_to :human_message, optional: true

  validates :direction, inclusion: { in: DIRECTIONS }
  validates :jti, :issuer, :audience, :key_id, :pr_url, :repo, :pr_number, :head_sha, :approver, :channel,
            :read_back, :answer, :approved_at, :issued_at, :expires_at, presence: true
  validates :outcome, inclusion: { in: OUTCOMES }, allow_nil: true

  scope :issued, -> { where(direction: ISSUED) }
  scope :received, -> { where(direction: RECEIVED) }

  before_update do
    frozen = changed - MUTABLE_ATTRIBUTES
    # The HumanMessage is written after the row (it cites the row's id), so the
    # link is set once, from empty.
    frozen -= [ "human_message_id" ] if human_message_id_was.nil?
    raise ActiveRecord::ReadOnlyRecord, "MergeAttestation is read-only once recorded (#{frozen.join(', ')})" if frozen.any?
  end
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "MergeAttestation is read-only once recorded" }
end
