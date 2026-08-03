# frozen_string_literal: true

# Helpers for the per-session state that lives on the durable `zimmer_data`
# volume next to the clone: the scratch directory (SessionScratchDirectory) and
# prompt attachments (FileStorageService / ImageStorageService).
#
# Why this is grouped apart from the clone
# ----------------------------------------
# A clone is reconstructable — unarchive re-clones from the remote and replays
# preserved artifacts on top — so it is reaped as soon as the undo window
# closes. Scratch and prompt attachments have no remote to come back from: once
# deleted they are gone, and UnarchiveSessionService has nothing to restore
# them from. Archive is reversible for SessionStateMachine::TRASH_RETENTION_PERIOD,
# so this state is held for that window and reaped by EmptyTrashJob at the trash
# deadline — the same lifecycle preserved clone artifacts already get.
module DurableSessionStorage
  extend ActiveSupport::Concern

  private

  # Whether any durable side-state exists on disk for the session.
  def durable_session_storage_exists?(session_id)
    scratch_dir_exists?(session_id) || prompt_attachments_exist?(session_id)
  end

  def scratch_dir_exists?(session_id)
    Dir.exist?(SessionScratchDirectory.path_for(session_id))
  rescue ArgumentError
    false
  end

  def prompt_attachments_exist?(session_id)
    Dir.exist?(FileStorageService.new(session_id: session_id).session_dir) ||
      Dir.exist?(ImageStorageService.new(session_id: session_id).session_dir)
  rescue ArgumentError
    false
  end

  # Deletes the scratch directory and prompt attachments for a session.
  #
  # @return [Array<String>] human-readable descriptions of what was actually
  #   removed; empty when there was nothing on disk.
  def cleanup_durable_session_storage(session_id)
    removed = []

    if scratch_dir_exists?(session_id)
      SessionScratchDirectory.cleanup_for(session_id)
      removed << "scratch directory deleted"
    end

    if prompt_attachments_exist?(session_id)
      FileStorageService.cleanup_for(session_id)
      ImageStorageService.cleanup_for(session_id)
      removed << "prompt attachments deleted"
    end

    removed
  end
end
