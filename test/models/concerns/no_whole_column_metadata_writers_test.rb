require "test_helper"

# The structural half of #70. The behavioural tests next door prove that the
# converted call sites keep a concurrent writer's keys; this one proves there is
# nothing left to convert, and — more usefully — that a new one cannot be added
# without someone deciding to.
#
# It is a source scan rather than a runtime assertion because that is the only
# thing that covers all of `app/` at once. The shape it looks for is the one
# AtomicJsonMetadata replaces: a write to `metadata` / `custom_metadata` whose
# value was computed in Ruby from a copy of the same column read earlier.
#
#   session.update!(metadata: (session.metadata || {}).merge(...))   # flagged
#   session.update_column(:metadata, cleaned)                        # flagged
#   session.update!(metadata: { source: "quick_prompt" })            # not flagged
#
# ALLOWED lists the sites that are deliberately left alone, each with the reason.
# Adding to it is a decision, not a formality: the reason has to be that the write
# genuinely cannot race, not that converting it was inconvenient.
class NoWholeColumnMetadataWritersTest < ActiveSupport::TestCase
  SCANNED = Rails.root.join("app")

  # A `metadata:` / `custom_metadata:` keyword whose value is a parenthesised
  # expression or names something ending in `metadata`, or a direct
  # `update_column(s)` on either column.
  WHOLE_COLUMN = /
    (?:^|[\s(,])(?:custom_)?metadata:\s*(?:\(|[@\w.\[\]:]*metadata\b)
    |
    update_columns?\(\s*:?(?:custom_)?metadata
    |
    update_columns?\([^)]*,\s*(?:custom_)?metadata:
  /x

  # An in-memory assignment to either column. Whether it is safe depends on
  # whether the record is persisted, which no regex can tell — so every one is
  # listed and a new one has to be argued for.
  ASSIGNMENT = /(?:^|[\s(])(?:self|[@\w.]+)\.(?:custom_)?metadata\s*=[^=~]/

  ALLOWED = {
    # Creation paths: the row does not exist yet, so there is no other writer to
    # race with and no row to merge into.
    "models/session.rb" => [
      "metadata: metadata.merge(\"agent_root_key\" => agent_root_name)",
      "custom_metadata: custom_metadata,",
      # after_create, inside the create transaction — the row is not yet visible
      # to any other connection.
      "metadata: (metadata || {}).merge(\"auto_generated_title\" => true)",
      # The in-memory form, for the creation surfaces. Its persisted twin is
      # Session#record_explicit_mcp_servers!, which merges atomically.
      "self.metadata = remaining"
    ],
    "services/fork_session_service.rb" => [ "metadata: new_metadata," ],
    # Serializers, not writers.
    "controllers/concerns/api_session_serialization.rb" => [
      "metadata: session.metadata,", "custom_metadata: session.custom_metadata,"
    ],
    # Attribute assembly before Session.new / create — same reason as above.
    "controllers/sessions_controller.rb" => [
      "@session.metadata = (@session.metadata || {}).merge(\"agent_root_key\" => params[:agent_root_name])"
    ],
    "controllers/api/v1/sessions_controller.rb" => [
      "@session.metadata = (@session.metadata || {}).merge(\"agent_root_key\" => agent_root_name)"
    ],
    "services/mcp/tools/start_session.rb" => [
      "session.metadata = (session.metadata || {}).merge(\"agent_root_key\" => agent_root_name)"
    ],
    # Not a session column at all: a TokenUsage row's own `metadata`, rendered.
    "controllers/api/v1/costs_controller.rb" => [ "metadata: record.metadata" ],
    # Not a session column either: McpOauthService::OAuthRequirement's field.
    "services/mcp_oauth_service.rb" => [ "OAuthRequirement.new(required: true, metadata: metadata" ]
  }.freeze

  test "no whole-column session metadata writers remain in app/" do
    offenders = []

    Dir.glob(SCANNED.join("**/*.rb")).sort.each do |path|
      relative = Pathname.new(path).relative_path_from(SCANNED).to_s
      next if relative == "models/concerns/atomic_json_metadata.rb"

      allowed = ALLOWED.fetch(relative, [])

      File.readlines(path).each_with_index do |line, index|
        stripped = line.strip
        next if stripped.start_with?("#")
        next unless stripped.match?(WHOLE_COLUMN) || stripped.match?(ASSIGNMENT)
        next if allowed.any? { |snippet| stripped.include?(snippet) }

        offenders << "#{relative}:#{index + 1}  #{stripped}"
      end
    end

    assert_empty offenders, <<~MESSAGE
      These write a session JSON column from a Ruby-side copy of it. Two writers
      racing on the column erase each other's keys even when they touch different
      ones (#70). Use Session#merge_metadata! / #remove_metadata! (or the
      custom_metadata pair) instead, or add the site to ALLOWED here with the
      reason it cannot race:

      #{offenders.join("\n      ")}
    MESSAGE
  end

  # The scan is worth nothing if its regex has stopped matching the shape. This
  # pins it against the literal text of the writers that were converted.
  test "the scan still recognises the shape it exists to reject" do
    samples = [
      'session.update!(metadata: (session.metadata || {}).merge("paused_by" => "user"))',
      "@session.update_columns(metadata: (@session.metadata || {}).merge(metadata_updates))",
      "session.update_column(:metadata, (session.metadata || {}).except(ATTEMPTS_KEY))",
      "update_column(:custom_metadata, metadata_hash.merge(\"needs_input_count\" => next_count))",
      "session.update!(running_job_id: nil, metadata: cleaned_metadata)",
      "session.update!(custom_metadata: merged_custom_metadata)"
    ]

    samples.each do |sample|
      assert sample.match?(WHOLE_COLUMN), "the scan no longer flags: #{sample}"
    end

    assert "self.metadata = remaining".match?(ASSIGNMENT)

    [
      'metadata: { source: "quick_prompt" },',
      'custom_metadata: { type: "object", description: CUSTOM_METADATA_DESC },',
      'session.merge_metadata!("paused_by" => "user")',
      "return nil if terminal.line == session.metadata&.dig(TERMINAL_API_ERROR_LINE_KEY)",
      'assert_equal 1, session.metadata["x"]'
    ].each do |sample|
      refute sample.match?(WHOLE_COLUMN), "the scan falsely flags: #{sample}"
      refute sample.match?(ASSIGNMENT), "the scan falsely flags as an assignment: #{sample}"
    end
  end
end
