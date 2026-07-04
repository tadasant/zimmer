namespace :maintenance do
  namespace :cleanup do
    desc "Safely clean up orphaned Claude CLI processes"
    task orphaned_processes: :environment do
      dry_run = ENV["DRY_RUN"] == "true"
      puts "=" * 80
      puts "Orphaned Process Cleanup Task"
      puts "Mode: #{dry_run ? 'DRY RUN (no changes will be made)' : 'ACTIVE (will terminate processes)'}"
      puts "=" * 80
      puts

      # Get all sessions with process_pid in metadata using PostgreSQL JSON query
      sessions_with_pids = Session.where.not(status: :archived)
                                   .where("metadata->>'process_pid' IS NOT NULL")
      puts "Found #{sessions_with_pids.count} session(s) with process PIDs in database"
      puts

      # Only proceed with cleanup if there are sessions with PIDs
      unless sessions_with_pids.empty?
        process_manager = SystemProcessManager.new
        orphaned_count = 0
        cleaned_count = 0
        permission_denied_count = 0
        errors = []

        sessions_with_pids.each do |session|
          pid = session.metadata["process_pid"]

          # Validate PID is a positive integer
          unless pid.is_a?(Integer) && pid > 0
            puts "Checking session #{session.id}..."
            puts "  ✗ Invalid PID: #{pid.inspect} (skipping)"
            next
          end

          puts "Checking session #{session.id} (PID: #{pid})..."

          # Check if process is actually running
          is_running = process_manager.running?(pid)

          if is_running
            puts "  ✓ Process #{pid} is running (session status: #{session.status})"
            next
          end

          # Process is not running - this is an orphaned PID reference
          orphaned_count += 1
          puts "  ✗ Process #{pid} not found (orphaned reference)"
          puts "    Session status: #{session.status}"
          puts "    Git root: #{session.git_root}"
          puts "    Created: #{session.created_at}"

          if dry_run
            puts "    [DRY RUN] Would update session to 'failed' status and clear PID"
          else
            begin
              # Update session to failed status and clear PID from metadata
              # Use deep_dup to avoid issues with nested hashes/arrays
              new_metadata = session.metadata.deep_dup
              new_metadata.delete("process_pid")
              new_metadata["cleanup_reason"] = "orphaned_pid"
              new_metadata["cleaned_at"] = Time.current.iso8601

              session.update!(
                status: :failed,
                metadata: new_metadata
              )

              # Log the cleanup action
              session.logs.create!(
                content: "Process #{pid} not found. Session marked as failed by orphaned process cleanup task.",
                level: "info"
              )

              cleaned_count += 1
              puts "    ✓ Updated session to failed status and cleared PID"
            rescue => e
              errors << "Session #{session.id}: #{e.message}"
              puts "    ✗ Error updating session: #{e.message}"
            end
          end
          puts
        end

        # Now check for running claude processes that aren't in our database
        puts "=" * 80
        puts "Checking for running Claude CLI processes not in database..."
        puts "=" * 80
        puts

        # Get all running claude processes
        # Using Open3 with array syntax to prevent command injection
        begin
          require "open3"
          ps_output, status = Open3.capture2("ps", "ax", "-o", "pid,command")

          if status.success?
            claude_processes = []
            ps_output.each_line do |line|
              # Look for claude command processes
              # Match patterns like: "claude -p ..." or paths containing claude
              if line.match?(/\bclaude\b.*-p\s/) || line.match?(/\/claude\s/)
                parts = line.strip.split(nil, 2)
                pid = parts[0].to_i
                command = parts[1]
                claude_processes << { pid: pid, command: command }
              end
            end

            puts "Found #{claude_processes.count} running Claude CLI process(es)"
            puts

            if claude_processes.any?
              # Check which ones are not in our database
              tracked_pids = sessions_with_pids.map { |s| s.metadata["process_pid"] }.compact
              untracked_processes = claude_processes.reject { |p| tracked_pids.include?(p[:pid]) }

              if untracked_processes.any?
                puts "Found #{untracked_processes.count} untracked Claude process(es):"
                untracked_processes.each do |proc|
                  puts "  PID #{proc[:pid]}: #{proc[:command][0..80]}..."
                  puts "    [WARNING] Process not tracked in database"

                  if dry_run
                    puts "    [DRY RUN] Would attempt to terminate this process"
                  else
                    puts "    [ACTIVE] Attempting to terminate..."

                    # Use ProcessTerminationService to safely terminate
                    termination_service = ProcessTerminationService.new(
                      process_pid: proc[:pid],
                      process_manager: process_manager
                    )

                    result = termination_service.terminate

                    if result.success?
                      cleaned_count += 1
                      puts "    ✓ #{result.message}"
                    elsif result.status == :permission_denied
                      permission_denied_count += 1
                      puts "    ✗ Permission denied - cannot terminate (different user)"
                    else
                      errors << "PID #{proc[:pid]}: #{result.message}"
                      puts "    ✗ #{result.message}"
                    end
                  end
                  puts
                end
              else
                puts "All running Claude processes are tracked in database."
              end
            end
          else
            puts "Warning: Could not retrieve process list (ps command failed)"
          end
        rescue => e
          puts "Error checking for untracked processes: #{e.message}"
          errors << "Process check failed: #{e.message}"
        end

        # Summary
        puts "=" * 80
        puts "Summary"
        puts "=" * 80
        puts "Orphaned PID references found: #{orphaned_count}"
        if dry_run
          puts "Mode: DRY RUN - no changes were made"
          puts "Run without DRY_RUN=true to apply changes"
        else
          puts "Sessions cleaned up: #{cleaned_count}"
          puts "Permission denied: #{permission_denied_count}"
          puts "Errors: #{errors.count}"

          if errors.any?
            puts
            puts "Errors encountered:"
            errors.each { |e| puts "  - #{e}" }
          end

          if permission_denied_count > 0
            puts
            puts "Note: #{permission_denied_count} process(es) could not be terminated due to"
            puts "permission issues. These processes are owned by a different user."
            puts "You may need to run this task with appropriate privileges or contact"
            puts "the system administrator to clean up these processes."
          end
        end
        puts "=" * 80
      else
        puts "No sessions with PIDs found. Nothing to clean up."
      end
    end
  end
end
