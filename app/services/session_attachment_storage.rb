# SessionAttachmentStorage - Shared lifecycle and path logic for session attachments.
#
# Attachments a human adds to a session prompt come in two flavours, each with
# its own subclass: images (ImageStorageService, sniffed and base64-inlined for
# the CLI) and everything else (FileStorageService, stored verbatim). Only the
# storing and reading differ. The lifecycle around them — where the bytes live,
# how a session's directory is derived, how a path is proven to be inside that
# directory, how the tree is reaped — is identical, and lives here once.
#
# Three non-obvious invariants are encoded below. Each was learned from an
# incident, and each is now written down in exactly one place:
#
#   1. Storage resolves under the durable `zimmer_data` volume shared by the web
#      and worker containers (.storage_root). Per-container /tmp is invisible to
#      the worker, which silently broke attachments (limitations #74).
#   2. The test root is namespaced per worker process (.base_dir), or parallel
#      test workers delete each other's session directories.
#   3. Durable storage is not wiped by container recreation, so it must be
#      reaped explicitly (.cleanup_for), or attachments accumulate forever.
#
# Subclass contract
# -----------------
# A subclass declares where its bytes live and how a single entry is written:
#
#   class ThingStorageService < SessionAttachmentStorage
#     STORAGE_SUBDIR = "agent-orchestrator-things"
#
#     def self.storage_env_var = "AGENT_THINGS_DIR"
#     def self.storage_subdir  = STORAGE_SUBDIR
#     def self.attachment_noun = "thing"
#
#     def store(...) = ...        # writes one attachment, returns a metadata Hash
#     def copy_entry(...) = ...   # re-stores one entry into another session
#   end
#
# Storage location:
#   <storage_root>/<session_id>/<subclass-chosen filename>
#
class SessionAttachmentStorage
  class << self
    # Environment variable that overrides .storage_root for this attachment kind
    # (e.g. "AGENT_IMAGES_DIR"). Subclasses must declare it.
    def storage_env_var
      raise NotImplementedError, "#{name} must declare .storage_env_var"
    end

    # Subdirectory, under the durable ~/.zimmer root, that holds this attachment
    # kind (e.g. "agent-orchestrator-images"). Subclasses must declare it.
    def storage_subdir
      raise NotImplementedError, "#{name} must declare .storage_subdir"
    end

    # Singular human word for one attachment ("image", "file"), used in log
    # lines so an operator can tell the two trees apart.
    def attachment_noun
      raise NotImplementedError, "#{name} must declare .attachment_noun"
    end
  end

  attr_reader :session_id, :file_system

  def initialize(session_id:, file_system: nil)
    # Validate session_id to prevent path traversal attacks
    # Accept positive integers OR strings matching temp_<uuid> pattern for pre-session uploads
    if session_id.is_a?(Integer) && session_id > 0
      @session_id = session_id.to_s
    elsif session_id.is_a?(String) && session_id.match?(/\Atemp_[a-f0-9\-]+\z/)
      @session_id = session_id
    else
      raise ArgumentError, "session_id must be a positive integer or temp_<uuid> string"
    end
    @file_system = file_system || RealFileSystemAdapter.new
  end

  # Store one attachment. Subclasses define the signature they accept and the
  # metadata Hash they return; every implementation returns at least { path: }.
  def store(**)
    raise NotImplementedError, "#{self.class.name} must implement #store"
  end

  # Re-store one already-stored entry into another session's storage.
  #
  # Called by .copy_from_temp on the SOURCE service, once per entry, with the
  # entry's bytes and the DESTINATION service. This is the hook where the two
  # attachment kinds genuinely differ: images are sniffed and re-encoded (and an
  # entry whose media type cannot be detected is dropped), while files recover
  # their sanitized original basename. Return nil to drop the entry.
  #
  # @param content [String] the entry's raw bytes
  # @param old_path [String] the entry's current path in the source session
  # @param destination [SessionAttachmentStorage] the service to store into
  # @return [Hash, nil] metadata for the new entry, or nil to skip it
  def copy_entry(content:, old_path:, destination:)
    raise NotImplementedError, "#{self.class.name} must implement #copy_entry"
  end

  # Check that a path exists and is inside this session's directory.
  # Uses File.expand_path to prevent path traversal attacks via ".." sequences.
  #
  # @param path [String] Path to check
  # @return [Boolean]
  def exists?(path)
    return false unless path.present?

    # Resolve any ".." or "." in the path to prevent traversal attacks
    resolved_path = File.expand_path(path)
    resolved_session_dir = File.expand_path(session_dir)

    # Ensure the resolved path is within our session directory
    return false unless resolved_path.start_with?(resolved_session_dir + "/") ||
                        resolved_path == resolved_session_dir

    @file_system.exists?(resolved_path)
  end

  # Clean up all attachments for this session.
  def cleanup!
    dir = session_dir
    return unless File.directory?(dir)

    FileUtils.rm_rf(dir)
  rescue => e
    Rails.logger.warn("Failed to cleanup #{self.class.attachment_noun}s for session #{session_id}: #{e.message}")
  end

  # List all attachments for this session.
  #
  # @return [Array<String>] Paths to stored attachments
  def list
    dir = session_dir
    return [] unless File.directory?(dir)

    Dir.glob(File.join(dir, "*")).select { |f| File.file?(f) }
  end

  # Get storage directory for this session.
  def session_dir
    File.join(self.class.base_dir, session_id.to_s)
  end

  # Copy attachments from a temporary session to the real session.
  # Used when creating a new session with pre-uploaded attachments.
  #
  # @param temp_session_id [String] The temporary session ID (temp_<uuid>)
  # @param new_session_id [Integer] The real session ID
  # @return [Array<Hash>] Updated attachment metadata with new paths
  def self.copy_from_temp(temp_session_id:, new_session_id:)
    temp_service = new(session_id: temp_session_id)
    new_service = new(session_id: new_session_id)

    copied = []

    temp_service.list.each do |old_path|
      begin
        content = File.binread(old_path)
        result = temp_service.copy_entry(content: content, old_path: old_path, destination: new_service)
        copied << result if result
      rescue => e
        Rails.logger.error("Failed to copy #{attachment_noun} from temp storage #{old_path}: #{e.message}")
        # Continue with other entries rather than failing entirely
      end
    end

    # Clean up temp directory
    temp_service.cleanup!

    copied
  end

  # Reclaim a session's stored attachments (best-effort; never raises).
  #
  # Now that storage is durable (see .storage_root) it is no longer wiped by
  # container recreation, so it must be reaped explicitly. Called from the clone
  # GC so attachments share the clone/scratch lifecycle rather than accumulating
  # on the shared volume forever.
  def self.cleanup_for(session_id)
    new(session_id: session_id).cleanup!
  rescue ArgumentError => e
    Rails.logger.warn("[#{name}] cleanup_for skipped invalid session #{session_id.inspect}: #{e.message}")
  end

  # Root of this attachment kind's storage tree, before per-session subdirectories.
  #
  # Resolves under the durable `zimmer_data` volume (~/.zimmer) — a sibling of
  # ClonesDirectory.base, the SAME mount that is bind-mounted into BOTH the web
  # and worker containers in production. This cross-container visibility is the
  # whole point: an upload written by the web role (Puma) has to be readable by
  # the agent running in the worker role (GoodJob :external). Per-container
  # `/tmp` is an ephemeral overlay that is NOT shared between the two roles, so
  # files written there never reach the worker (see limitations #74).
  #
  # Override with the subclass's .storage_env_var environment variable. If you
  # point it OUTSIDE the mounted named volume you MUST add a corresponding
  # durable volume mount that both roles share, or the worker will not see
  # uploads. Resolved at call time (never memoized) so tests that stub HOME and
  # ops that set the override are both honored without a process restart.
  def self.storage_root
    configured = ENV[storage_env_var].presence
    return File.expand_path(configured) if configured

    File.join(File.dirname(ClonesDirectory.base), storage_subdir)
  end

  # Root directory under which all session directories live.
  #
  # In production and development this is storage_root verbatim. In the test
  # environment it is namespaced per worker *process* so that parallel test
  # workers cannot delete each other's attachments.
  #
  # Parallel test workers run in separate processes, each with its own test
  # database. Because `fixtures :all` seeds every worker's database identically,
  # `Session.create!` hands out colliding ids across workers (and the service
  # tests pick random ids from the same range). All workers otherwise share the
  # single storage_root, so one worker's teardown `cleanup!` would wipe the
  # session directory another worker is still reading from — producing
  # intermittent ENOENT errors. Keying the root by Process.pid gives each worker
  # an isolated tree. See issues pulsemcp/pulsemcp#3455 and pulsemcp/pulsemcp#3741.
  def self.base_dir
    return storage_root unless Rails.env.test?

    File.join(storage_root, "test-worker-#{Process.pid}")
  end

  private

  def ensure_directory_exists(dir)
    return if File.directory?(dir)

    FileUtils.mkdir_p(dir, mode: 0o755)
  end
end
