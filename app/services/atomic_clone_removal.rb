# frozen_string_literal: true

# Deletes a clone directory so that, from every consumer's point of view, it
# either exists whole or does not exist at all.
#
# Why this is not `FileUtils.rm_rf`
# ---------------------------------
# `rm_rf` unlinks children bottom-up *under the live path* and removes the root
# last. Interrupt it partway — a deploy, a SIGTERM, the worker container being
# recreated — and the clone directory is still there, still named what every
# consumer expects, holding an arbitrary surviving subset of the tree in readdir
# order. Nothing marks it and nothing detects it, so the session running in it
# keeps running against a tree with holes in it and `air prepare` fails with
# ENOENT when the agent root's subdirectory is one of the casualties. Seven of 48
# clones on the production box were in that state when #411 was triaged.
#
# So: `rename(2)` the clone to a sibling path no consumer resolves, then delete
# the renamed copy. The rename is atomic and the sibling shares the clones base,
# so it stays on one filesystem. An interrupt therefore leaves either the whole
# tree at its original path or nothing at it — never a half-tree wearing the
# clone's name. What it can leave behind is a `<clone>.deleting-<hex>` tombstone,
# which is exactly what the hourly sweeps reap (see .reap_tombstones).
#
# Failure of the rename itself
# ----------------------------
# A cross-device rename (EXDEV) or a permission error must NOT silently skip the
# delete: the bytes would leak forever and, on the archive path, the caller
# believes the clone is gone. The fallback is therefore an in-place `rm_rf`,
# logged at `.warn` — one narrow case that keeps the hazard described above,
# taken deliberately and visibly, rather than a different one taken silently.
module AtomicCloneRemoval
  # Marker for a directory that is mid-deletion. Chosen so it cannot collide with
  # a clone name (`<repo>-<branch>-<timestamp>-<random>`) — the hex run is
  # anchored to the end of the name — and so an operator reading `ls` can tell at
  # a glance what it is.
  TOMBSTONE_MARKER = ".deleting-"

  TOMBSTONE_PATTERN = /#{Regexp.escape(TOMBSTONE_MARKER)}\h{8}\z/

  # Blast-radius cap for one reap pass. Tombstones only accumulate when deletes
  # are being interrupted, so a run that hits this cap is itself a signal; the
  # rest are picked up by the next hourly sweep.
  REAP_LIMIT = 50

  module_function

  # Whether a directory name (or path) is a deletion tombstone rather than a clone.
  #
  # @param name [String] a basename or a full path
  # @return [Boolean]
  def tombstone?(name)
    TOMBSTONE_PATTERN.match?(File.basename(name.to_s))
  end

  # Remove a clone directory atomically.
  #
  # @param path [String] the clone directory
  # @param file_system [FileSystemAdapter] injected for the call sites that own one
  # @return [Boolean] true when there was something to remove
  def remove(path, file_system: RealFileSystemAdapter.new)
    # Not `blank?`: a Pathname answers `empty?`, and Pathname#empty? is true for an
    # empty *directory* — so `blank?` would silently decline to delete a clone whose
    # `git clone` was killed before it wrote anything. Two of the call sites hand
    # this a Pathname.
    return false if path.nil? || path.to_s.empty?
    return false unless file_system.exists?(path)

    # Already unresolvable by any consumer — deleting in place is what "delete the
    # renamed copy" means, and renaming again would just nest tombstones.
    if tombstone?(path)
      file_system.rm_rf(path)
      return true
    end

    tombstone = tombstone_path_for(path)

    begin
      file_system.rename(path, tombstone)
    rescue Errno::ENOENT
      # Another reaper got there first. Nothing to report.
      return false
    rescue SystemCallError => e
      Rails.logger.warn "[AtomicCloneRemoval] Could not rename #{path} aside before deleting " \
        "(#{e.class}: #{e.message}); falling back to a non-atomic in-place delete"
      file_system.rm_rf(path)
      return true
    end

    # Deliberately not rescued: the clone is already gone from its own name, which
    # is the guarantee this module exists for. A failure here leaves a tombstone
    # the sweeps reap, and the caller's own error handling still sees the fault.
    # `FileUtils.rm_rf` swallows its own errors, so in practice only an injected
    # adapter raises — which is what makes "the path is already clear" the useful
    # guarantee rather than the return value.
    file_system.rm_rf(tombstone)
    true
  end

  # Delete tombstones left under `base` by an interrupt between the rename and the
  # recursive delete. Called by the two hourly clone sweeps.
  #
  # No age bar: a tombstone is doomed by construction, so there is no window in
  # which one is still wanted. Racing a live `remove` that is mid-`rm_rf` is
  # harmless — both processes are deleting the same doomed tree and `rm_rf`
  # ignores files that vanish under it.
  #
  # Docker Compose teardown is deliberately not attempted here. Every call site that
  # can have compose resources tears them down before it asks for the delete, so a
  # tombstone's teardown has already happened; and this runs on the disk-pressure
  # path, where `COMPOSE_DOWN_TIMEOUT` (120s) per directory would blow the sweep's
  # wall-clock budget many times over.
  #
  # @param base [String] the clones base directory
  # @param limit [Integer] most tombstones to remove in one pass
  # @return [Integer] how many were removed
  def reap_tombstones(base, limit: REAP_LIMIT)
    return 0 if base.nil? || base.to_s.empty? || !File.directory?(base)

    tombstones = begin
      Dir.children(base).select { |entry| tombstone?(entry) }
    rescue SystemCallError => e
      Rails.logger.error "[AtomicCloneRemoval] Failed to list #{base} for tombstones: #{e.class} - #{e.message}"
      return 0
    end

    return 0 if tombstones.empty?

    reaped = 0

    tombstones.first(limit).each do |entry|
      full_path = File.join(base, entry)

      # No `File.directory?` guard: a tombstone can be a file or a dangling symlink
      # (ForkSessionService disposes of a destination that may be "a partially
      # written tree, a bare directory, or nothing"), and skipping those would leak
      # them forever.
      FileUtils.rm_rf(full_path)

      # `rm_rf` is `rm_r(force: true)`: it swallows every error and returns
      # normally, so the count cannot come from the call. An unwritable subtree
      # would otherwise be reported as reaped on every run, forever, while sitting
      # on disk and consuming one of the REAP_LIMIT slots in silence.
      if File.exist?(full_path) || File.symlink?(full_path)
        Rails.logger.warn "[AtomicCloneRemoval] Tombstone #{full_path} survived its reap; " \
          "leaving it for the next sweep"
        next
      end

      reaped += 1
    rescue StandardError => e
      Rails.logger.error "[AtomicCloneRemoval] Failed to reap tombstone #{full_path}: #{e.class} - #{e.message}"
    end

    remaining = tombstones.size - reaped
    Rails.logger.info "[AtomicCloneRemoval] Reaped #{reaped} interrupted-delete tombstone(s) under #{base}" \
      "#{remaining > 0 ? " (#{remaining} left for the next sweep)" : ""}"

    reaped
  end

  # A sibling of `path` — same directory, therefore same filesystem, therefore an
  # atomic rename.
  def tombstone_path_for(path)
    # File.dirname and File.basename both ignore trailing separators, so a path
    # handed over as "<clone>/" still yields a sibling rather than a child.
    File.join(
      File.dirname(path.to_s),
      "#{File.basename(path.to_s)}#{TOMBSTONE_MARKER}#{SecureRandom.hex(4)}"
    )
  end
end
