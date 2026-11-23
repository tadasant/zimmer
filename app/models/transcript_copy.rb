# frozen_string_literal: true

# A verified copy of a session's transcript in object storage. Written by
# TranscriptCopier only after every object has been read back and checked, so a row means
# the bytes are there. `session` is nil once the session is deleted; the copy is not.
class TranscriptCopy < ApplicationRecord
  belongs_to :session, optional: true

  validates :bucket, :manifest_object, :transcript_object, :transcript_digest, :verified_at, presence: true

  def manifest_uri = "gs://#{bucket}/#{manifest_object}"

  def transcript_uri = "gs://#{bucket}/#{transcript_object}"
end
