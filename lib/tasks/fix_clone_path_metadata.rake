namespace :data do
  desc "Fix sessions with broken clone_path metadata (Hash instead of String)"
  task fix_clone_path_metadata: :environment do
    puts "Finding sessions with broken clone_path metadata..."

    broken_sessions = Session.where.not(metadata: nil).select do |session|
      clone_path_value = session.metadata&.dig("clone_path")
      clone_path_value.is_a?(Hash)
    end

    puts "Found #{broken_sessions.count} sessions with broken metadata"

    broken_sessions.each do |session|
      puts "Fixing session #{session.id} (#{session.slug})..."

      old_metadata = session.metadata.dup
      clone_path_hash = session.metadata["clone_path"]

      # Extract the actual paths from the nested hash
      actual_clone_path = clone_path_hash["clone_path"] || clone_path_hash[:clone_path]
      actual_working_dir = clone_path_hash["working_directory"] || clone_path_hash[:working_directory]

      # Update metadata with correct structure
      new_metadata = session.metadata.dup
      new_metadata["clone_path"] = actual_clone_path
      new_metadata["working_directory"] = actual_working_dir

      session.update!(metadata: new_metadata)

      puts "  Old: clone_path = #{old_metadata['clone_path'].inspect}"
      puts "  New: clone_path = #{actual_clone_path.inspect}"
      puts "       working_directory = #{actual_working_dir.inspect}"
    end

    puts "Done! Fixed #{broken_sessions.count} sessions"
  end
end
