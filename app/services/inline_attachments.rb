# frozen_string_literal: true

# Attachments carried inline on a JSON request — `[{ filename:, media_type:, data: }]`,
# `data` base64 with or without a `data:<type>;base64,` prefix — stored in a session's
# own storage the way the web composer's upload endpoints store theirs, and handed to
# the turn as the `images:` and `files:` descriptors it reads.
#
# Two callers, one rule: a follow-up (`Api::V1::SessionsController#follow_up`) and a
# Quick Router start (`Api::V1::QuickRouterController#create`), both from the iOS app.
# One bad attachment refuses the whole message rather than sending it without, because
# an agent answering about a file it never received is the failure the person would
# not see; what was stored before the bad one is removed.
#
# Which it is goes by the bytes, as ImageStorageService reads them: a PNG, JPEG, GIF or
# WebP is an image whatever `media_type` says, and anything else is a file.
#
# `parse` does every check that needs no session — the shape, the count, the base64,
# the total — so a caller that has not created its session yet can refuse before it
# does; `store` then writes the parsed bytes under the session's id.
class InlineAttachments
  # The most one message carries: the web composer's image cap.
  LIMIT = 20
  # The most their decoded bytes may add up to, and the most a body may be: base64 is
  # four bytes for every three, and a JSON encoder may escape its slashes, so 75 MB of
  # attachments needs a little over 100 MB of body.
  TOTAL_BYTES = 75.megabytes
  BODY_LIMIT = 110.megabytes

  # Why the attachments were refused. `title` is the API error's short name.
  class Invalid < StandardError
    attr_reader :title

    def initialize(message, title: "Invalid attachment")
      super(message)
      @title = title
    end
  end

  Parsed = Data.define(:filename, :bytes)

  class << self
    # @param raw [Array, nil] the request's `attachments`
    # @param noun [String] what carries them, for the messages ("follow-up", "Quick Router prompt")
    # @return [Array<Parsed>] empty when there were none
    # @raise [Invalid]
    def parse(raw, noun: "follow-up")
      return [] if raw.blank?
      raise Invalid.new("attachments must be a list") unless raw.is_a?(Array)
      if raw.size > LIMIT
        raise Invalid.new("A #{noun} carries at most #{LIMIT} attachments", title: "Too many attachments")
      end

      total = 0
      raw.map do |entry|
        unless entry.is_a?(ActionController::Parameters) || entry.is_a?(Hash)
          raise Invalid.new("Each attachment is an object with a filename and data")
        end

        filename = entry["filename"].to_s
        bytes = decode(entry["data"].to_s)
        raise Invalid.new("Each attachment needs a filename and data") if filename.blank? || bytes.empty?

        total += bytes.bytesize
        if total > TOTAL_BYTES
          raise Invalid.new("A #{noun}'s attachments may add up to at most #{TOTAL_BYTES / 1.megabyte} MB")
        end

        Parsed.new(filename: filename, bytes: bytes)
      end
    end

    # Store parsed attachments under `session_id` and return `{ images:, files: }`, each nil
    # when there are none. Removes what it stored if a later one is refused.
    #
    # @return [Hash{Symbol=>Array<Hash>, nil}]
    # @raise [Invalid]
    def store(parsed, session_id:)
      staged = { images: [], files: [] }
      parsed.each do |attachment|
        images_store = ImageStorageService.new(session_id: session_id)
        if images_store.media_type_of(attachment.bytes)
          stored = images_store.store(bytes: attachment.bytes, filename: attachment.filename)
          staged[:images] << { path: stored[:path], media_type: stored[:media_type] }
        else
          stored = FileStorageService.new(session_id: session_id).store(data: attachment.bytes, filename: attachment.filename)
          staged[:files] << { path: stored[:path], original_filename: stored[:original_filename], size: stored[:size] }
        end
      end
      { images: staged[:images].presence, files: staged[:files].presence }
    rescue ImageStorageService::InvalidImageError, FileStorageService::InvalidFileError => e
      discard(staged)
      raise Invalid.new(e.message)
    end

    # `parse` then `store`, for a caller whose session already exists.
    def stage(raw, session_id:, noun: "follow-up")
      store(parse(raw, noun: noun), session_id: session_id)
    end

    # Remove what a refused message stored, so a client that retries does not pile copies
    # into the session's storage.
    def discard(staged)
      return if staged.nil?

      (Array(staged[:images]) + Array(staged[:files])).each do |descriptor|
        path = descriptor[:path]
        File.delete(path) if path && File.exist?(path)
      end
    rescue SystemCallError => e
      Rails.logger.warn("[InlineAttachments] Could not remove a refused message's attachment: #{e.message}")
    end

    private

    def decode(data)
      Base64.strict_decode64(data.sub(/\Adata:[^;,]+;base64,/, ""))
    rescue ArgumentError
      raise Invalid.new("An attachment's data is not valid base64")
    end
  end
end
