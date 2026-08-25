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
# so it stays on one filesystem. An interrupt now leaves either the whole tree at
# its original path or nothing at it — never a half-tree wearing the clone's name.
# What it can leave behind is a `<clone>.deleting-<hex>` tombstone, which is
# exactly what the hourly sweeps reap (see .reap_tombstones).
#
# Failure of the rename itself
# ----------------------------
# A cross-device rename (EXDEV) or a permission error must NOT silently skip the
# delete: the bytes would leak forever and, on the archive path, the caller
# believes the clone is gone. So the fallback is the old in-place `rm_rf`, logged
# at `.warn` — the pre-existing hazard, taken deliberately and visibly, rather
# than a new one.
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
    return false if path.blank?
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
  # @param base [String] the clones base directory
  # @param limit [Integer] most tombstones to remove in one pass
  # @return [Integer] how many were removed
  def reap_tombstones(base, limit: REAP_LIMIT)
    return 0 if base.blank? || !File.directory?(base)

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
      next unless File.directory?(full_path)

      FileUtils.rm_rf(full_path)
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
    cleaned = path.to_s.chomp(File::SEPARATOR)

    File.join(
      File.dirname(cleaned),
      "#{File.basename(cleaned)}#{TOMBSTONE_MARKER}#{SecureRandom.hex(4)}"
    )
  end
end
