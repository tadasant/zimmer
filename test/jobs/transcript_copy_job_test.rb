# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "support/fake_gcs"

# TranscriptCopyJob against the real client and a fake store over HTTP. The two things
# that matter: a TranscriptCopy row exists only when the bytes are really there, and
# nothing in Postgres is changed or deleted.
class TranscriptCopyJobTest < ActiveJob::TestCase
  setup do
    @gcs = FakeGcs.start
    configure(TranscriptStorage::BUCKET => "zimmer-transcripts", TranscriptStorage::KEY_JSON => FakeGcs.key_json)
  end

  teardown do
    @gcs.stop
    ENV.delete(TranscriptCopyJob::COPY_AFTER_DAYS_ENV)
  end

  def configure(values)
    chain = SecretProviders::Chain.new([ SecretProviders::Env.new(values) ])
    env = { TranscriptStorage::API_BASE => @gcs.url, TranscriptStorage::TOKEN_URL => "#{@gcs.url}/token" }
    TranscriptStorage.unstub(:configuration)
    configuration = TranscriptStorage.configuration(chain: chain, env: env)
    TranscriptStorage.stubs(:configuration).returns(configuration)
    configuration
  end

  def jsonl(count, text: "héllo")
    (0...count).map do |i|
      JSON.generate(type: i.even? ? "user" : "assistant", uuid: "u#{i}", timestamp: "2026-11-01T00:00:00Z",
        message: { role: i.even? ? "user" : "assistant", content: "#{text} #{i}" }, filler: "x" * 300)
    end.join("\n") + "\n"
  end

  def archived_session(content: jsonl(1_500), archived_at: 8.days.ago)
    session = create_session(prompt: "copy me")
    session.update!(transcript: content)
    session.update_columns(status: Session.statuses.fetch("archived"), archived_at: archived_at)
    session.reload
  end

  def add_subagent(session, text, agent_id: "agent/1")
    SubagentTranscript.create!(session: session, agent_id: agent_id, transcript: text, subagent_type: "Explore", description: "look", status: "completed", filename: "a.jsonl")
  end

  def retry_now(session)
    Session.where(id: session.id).update_all([ "metadata = metadata - ?::text", TranscriptCopyJob::RETRY_AT_KEY ])
  end

  def gunzip(bytes) = Zlib::GzipReader.new(StringIO.new(bytes)).read.force_encoding("UTF-8")

  def object(name) = @gcs.objects.fetch(name)

  test "copies a transcript and its subagents, readable without Zimmer, and records where" do
    content = jsonl(1_500)
    session = archived_session(content: content)
    add_subagent(session, "{\"type\":\"user\"}\n")
    chunks = SessionTranscriptChunk.where(session_id: session.id).order(:seq).pluck(:id, :content)
    assert_operator chunks.size, :>, 1
    before = session.reload.attributes

    result = TranscriptCopyJob.perform_now

    assert_equal({ copied: 1, skipped: 0, failed: 0, store_failed: 0, bytes: content.bytesize }, result)
    copy = TranscriptCopy.find_by!(session_id: session.id)
    prefix = "test/sessions/#{session.created_at.utc.strftime("%Y/%m")}/#{session.id}"
    assert_equal "#{prefix}/transcript-#{session.transcript_digest}.jsonl.gz", copy.transcript_object
    assert_equal "gs://zimmer-transcripts/#{copy.transcript_object}", copy.transcript_uri
    assert_equal content, gunzip(object(copy.transcript_object).bytes)
    assert_equal object(copy.transcript_object).generation, copy.transcript_generation
    assert_equal "application/gzip", object(copy.transcript_object).content_type
    assert_equal session.transcript_digest, object(copy.transcript_object).metadata["sha256"]
    assert_equal content.bytesize, copy.transcript_byte_size
    assert_equal 1_500, copy.transcript_line_count

    manifest = JSON.parse(object(copy.manifest_object).bytes)
    assert_equal "zimmer.transcript/v1", manifest["schema"]
    assert_equal session.id, manifest["session"]["id"]
    assert_equal copy.transcript_object, manifest["transcript"]["object"]
    assert_equal copy.transcript_generation, manifest["transcript"]["generation"]
    subagent = manifest["subagents"].sole
    assert_match %r{/subagents/agent_1-\h{64}\.jsonl\.gz\z}, subagent["object"]
    assert_equal "{\"type\":\"user\"}\n", gunzip(object(subagent["object"]).bytes)
    assert_equal copy.subagents.sole["object"], subagent["object"]
    assert_equal [ "agent/1", "a.jsonl" ], subagent.values_at("agent_id", "filename")
    assert_equal object(copy.transcript_object).bytes.bytesize, copy.transcript_compressed_bytes

    # A measure of the conversation alone, far smaller than the transcript.
    assert_operator copy.conversation_byte_size, :>, 1_500 * 5
    assert_operator copy.conversation_byte_size, :<, content.bytesize / 5

    # Nothing in Postgres changed.
    assert_equal before, Session.find(session.id).attributes
    assert_equal chunks, SessionTranscriptChunk.where(session_id: session.id).order(:seq).pluck(:id, :content)
  end

  test "copies once, and again only when the transcript or a subagent has changed" do
    session = archived_session(content: jsonl(5))
    assert_equal 1, TranscriptCopyJob.perform_now[:copied]
    assert_equal 0, TranscriptCopyJob.perform_now[:copied]

    travel 1.minute do
      add_subagent(session, "{\"late\":true}\n")
      assert_equal 1, TranscriptCopyJob.perform_now[:copied]
      assert_equal 0, TranscriptCopyJob.perform_now[:copied]
    end

    first = TranscriptCopy.where(session_id: session.id).pluck(:transcript_object).uniq
    session.reload.update!(transcript: jsonl(9))
    session.update_columns(status: Session.statuses.fetch("archived"), archived_at: 8.days.ago)
    assert_equal 1, TranscriptCopyJob.perform_now[:copied]
    assert_equal 3, TranscriptCopy.where(session_id: session.id).count
    assert first.all? { |name| @gcs.objects.key?(name) }, "the earlier version stays"
  end

  test "leaves recent archives and live sessions alone, and honours the age setting" do
    recent = archived_session(content: jsonl(3), archived_at: 3.days.ago)
    live = create_session(prompt: "live")
    live.update!(transcript: jsonl(3))

    assert_equal 0, TranscriptCopyJob.perform_now[:copied]

    ENV[TranscriptCopyJob::COPY_AFTER_DAYS_ENV] = "2"
    assert_equal 1, TranscriptCopyJob.perform_now[:copied]
    assert TranscriptCopy.exists?(session_id: recent.id)
  end

  test "off without configuration: no request, no row, no warning" do
    archived_session(content: jsonl(3))
    assert configure({}).off?
    Rails.logger.expects(:warn).never

    assert_equal 0, TranscriptCopyJob.perform_now[:copied]
    assert_empty @gcs.calls
  end

  test "half a configuration copies nothing and says which half is missing" do
    archived_session(content: jsonl(3))

    assert_match(/KEY_JSON is not/, configure(TranscriptStorage::BUCKET => "zimmer-transcripts").problem)
    assert_equal 0, TranscriptCopyJob.perform_now[:copied]
    assert_match(/BUCKET is not/, configure(TranscriptStorage::KEY_JSON => FakeGcs.key_json).problem)
    assert_match(/not a bucket name/, configure(TranscriptStorage::BUCKET => "a/b", TranscriptStorage::KEY_JSON => FakeGcs.key_json).problem)
    broken = configure(TranscriptStorage::BUCKET => "zimmer-transcripts", TranscriptStorage::KEY_JSON => "hunter2")
    assert_not_includes broken.problem, "hunter2"
    assert_not_includes broken.inspect, "hunter2"
    assert_empty @gcs.calls
  end

  test "no row when the store serves back something else" do
    session = archived_session(content: jsonl(3))
    [ ->(bytes) { bytes[0..-9] }, ->(_bytes) { "not gzip" }, ->(_bytes) { Zlib.gzip("{}\n") }, ->(_bytes) { "" },
      ->(bytes) { bytes + "JUNK" }, ->(bytes) { bytes + Zlib.gzip("{}\n") } ].each do |tamper|
      @gcs.tamper = tamper
      assert_equal 1, TranscriptCopyJob.perform_now[:failed]
      assert_not TranscriptCopy.exists?(session_id: session.id)
      retry_now(session)
    end

    @gcs.tamper = nil
    assert_equal 1, TranscriptCopyJob.perform_now[:copied], "the objects already there are adopted once they verify"
  end

  test "ends the tick after repeated failures, and quotes no response body" do
    5.times { archived_session(content: jsonl(2)) }
    @gcs.refuse = 403
    logged = []
    Rails.logger.stubs(:error).with { |message| logged << message }

    assert_equal TranscriptCopyJob::MAX_STORE_FAILURES, TranscriptCopyJob.perform_now[:store_failed]
    assert_equal 0, TranscriptCopyJob.failing.count, "no session is blamed for the store"
    assert logged.any? { |message| message.include?("HTTP 403") }
    assert logged.none? { |message| message.include?("denied") }
    assert_equal 0, TranscriptCopy.count
  end

  test "a store that cannot be reached is a failure, not an exception" do
    archived_session(content: jsonl(2))
    @gcs.stop

    assert_equal 1, TranscriptCopyJob.perform_now[:store_failed]
  end

  test "does not send the transcript where an upload is redirected" do
    archived_session(content: jsonl(2))
    @gcs.location_base = "http://elsewhere.invalid"

    assert_equal 1, TranscriptCopyJob.perform_now[:store_failed]
    assert @gcs.calls.none? { |verb, *| verb == "PUT" }
  end

  test "chunks that disagree with the row are set aside until the transcript changes" do
    session = archived_session(content: jsonl(5))
    updated_at = session.updated_at
    SessionTranscriptChunk.where(session_id: session.id).order(:seq).last.update_columns(content: "tampered\n")

    assert_equal 1, TranscriptCopyJob.perform_now[:skipped]
    assert_equal 0, TranscriptCopyJob.perform_now.except(:bytes).values.sum
    assert_equal 1, TranscriptCopyJob.skipped.count
    assert_empty @gcs.objects
    assert_equal updated_at.to_f, session.reload.updated_at.to_f

    session.update!(transcript: jsonl(6))
    session.update_columns(status: Session.statuses.fetch("archived"), archived_at: 8.days.ago)
    assert_equal 1, TranscriptCopyJob.perform_now[:copied]
  end

  test "a transcript rewritten while it is read is not set aside" do
    session = archived_session(content: jsonl(5))
    SessionTranscriptChunk.where(session_id: session.id).order(:seq).last.update_columns(content: "moved\n")
    copier = TranscriptCopier.new(TranscriptStorage.configuration.client)
    stale = Session.find(session.id)
    Session.where(id: session.id).update_all(transcript_digest: "a" * 64)
    Session.stubs(:find_by).with(id: session.id).returns(stale)

    assert_raises(TranscriptCopier::Moved) { copier.copy(session.id) }
  end

  test "stops at the slice budget" do
    2.times { archived_session(content: jsonl(2)) }

    assert_equal 0, TranscriptCopyJob.perform_now(budget: 0)[:copied]
    assert_equal 2, TranscriptCopyJob.perform_now[:copied]
  end

  test "the record outlives the session" do
    session = archived_session(content: jsonl(2))
    TranscriptCopyJob.perform_now

    session.reload.destroy!

    copy = TranscriptCopy.find_by!(session_id: session.id)
    assert_nil copy.session
    assert @gcs.objects.key?(copy.transcript_object)
  end

  test "an unrenderable line costs the measurement, not the copy" do
    archived_session(content: "not json\n" * 3)
    SessionConversationText.any_instance.stubs(:line).raises("no")

    assert_equal 1, TranscriptCopyJob.perform_now[:copied]
    assert_nil TranscriptCopy.last.conversation_byte_size
  end

  test "sessions that fail for their own reasons wait, and do not hold up the rest" do
    bad = 4.times.map { |n| archived_session(content: jsonl(2, text: "bad#{n}"), archived_at: (20 - n).days.ago) }
    good = archived_session(content: jsonl(2))
    bad_names = bad.map { |session| session.transcript_digest }
    @gcs.tamper = ->(bytes) { bytes.start_with?("{") || bad_names.exclude?(Digest::SHA256.hexdigest(Zlib.gunzip(bytes))) ? bytes : "junk" }

    result = TranscriptCopyJob.perform_now

    assert_equal [ 1, 4, 0 ], result.values_at(:copied, :failed, :store_failed)
    assert TranscriptCopy.exists?(session_id: good.id)
    assert_equal 4, TranscriptCopyJob.failing.count
    assert_equal 0, TranscriptCopyJob.perform_now.except(:bytes).values.sum, "not retried at once"

    @gcs.tamper = nil
    travel(25.hours) { assert_equal 4, TranscriptCopyJob.perform_now[:copied] }
  end

  test "an unexpected error is one session's, and its message is not logged" do
    2.times { archived_session(content: jsonl(2)) }
    TranscriptCopier.any_instance.stubs(:copy).raises(ArgumentError, "secret transcript text").then.returns(nil)
    logged = []
    Rails.logger.stubs(:error).with { |message| logged << message }

    assert_equal [ 1, 1 ], TranscriptCopyJob.perform_now.values_at(:failed, :skipped)
    assert logged.none? { |message| message.include?("secret") }
  end

  test "a subagent write whose time is already past still makes the copy stale" do
    session = archived_session(content: jsonl(3))
    subagent = add_subagent(session, "one\n")
    TranscriptCopyJob.perform_now
    assert_equal 0, TranscriptCopyJob.candidates(bucket: "zimmer-transcripts").count

    subagent.update_columns(transcript: "two\n", updated_at: 1.day.ago)
    assert_equal 1, TranscriptCopyJob.perform_now[:copied]
    subagent.destroy!
    assert_equal 1, TranscriptCopyJob.perform_now[:copied]
    assert_equal 0, TranscriptCopyJob.perform_now[:copied]
  end

  test "a copy in another bucket does not count" do
    archived_session(content: jsonl(3))
    TranscriptCopyJob.perform_now
    @gcs.objects.clear
    configure(TranscriptStorage::BUCKET => "another-bucket", TranscriptStorage::KEY_JSON => FakeGcs.key_json)

    assert_equal 1, TranscriptCopyJob.perform_now[:copied]
    assert_equal %w[another-bucket zimmer-transcripts], TranscriptCopy.distinct.pluck(:bucket).sort
  end

  test "a recreated object's generation replaces the one that is gone" do
    session = archived_session(content: jsonl(3))
    TranscriptCopyJob.perform_now
    copy = TranscriptCopy.find_by!(session_id: session.id)
    old = copy.manifest_generation
    @gcs.objects.delete(copy.manifest_object)
    TranscriptCopier.new(TranscriptStorage.configuration.client).copy(session.id)

    assert_equal object(copy.manifest_object).generation, copy.reload.manifest_generation
    assert_not_equal old, copy.manifest_generation
    assert_equal 1, TranscriptCopy.where(session_id: session.id).count
  end

  test "a name taken while it is being uploaded is verified and adopted" do
    session = archived_session(content: jsonl(3))
    @gcs.before_finish = ->(name, body) { @gcs.objects[name] ||= FakeGcs::Stored.new(bytes: body, generation: 7) }

    assert_equal 1, TranscriptCopyJob.perform_now[:copied]
    assert_equal 7, TranscriptCopy.find_by!(session_id: session.id).transcript_generation
  end

  test "looks before it uploads, so an existing object needs no permission to overwrite" do
    archived_session(content: jsonl(3))
    TranscriptCopyJob.perform_now
    TranscriptCopy.delete_all
    @gcs.calls.clear

    assert_equal 1, TranscriptCopyJob.perform_now[:copied]
    assert @gcs.calls.none? { |verb, path, *| verb != "GET" && path != "/token" }
  end

  test "a token endpoint that does not answer is the store's failure" do
    archived_session(content: jsonl(2))
    ParameterStore::ServiceAccount.any_instance.stubs(:access_token).raises(Net::OpenTimeout)

    assert_equal 1, TranscriptCopyJob.perform_now[:store_failed]
  end

  test "a key that cannot sign is a configuration problem" do
    key = JSON.generate(client_email: "a@b", private_key: "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----")

    assert_match(/cannot be read/, configure(TranscriptStorage::BUCKET => "zimmer-transcripts", TranscriptStorage::KEY_JSON => key).problem)
  end

  test "a mismatch found at one digest does not set aside another" do
    session = archived_session(content: jsonl(3))
    TranscriptCopier.any_instance.stubs(:copy).raises(TranscriptCopier::Mismatch.new("no", digest: "old"))

    TranscriptCopyJob.perform_now

    assert_nil session.reload.metadata[TranscriptCopyJob::SKIPPED_DIGEST_KEY]
  end

  test "measuring a line that is not JSON logs none of it" do
    session = archived_session(content: "my private words\n")
    Rails.logger.expects(:warn).never

    assert_equal "", SessionConversationText.new(session).line("my private words\n", 0)
  end

  test "a connection dropped during the read-back is the store's failure, not the session's" do
    archived_session(content: jsonl(50))
    @gcs.cut_short = true

    assert_equal 1, TranscriptCopyJob.perform_now[:store_failed]
    assert_equal 0, TranscriptCopyJob.failing.count
    assert_equal 0, TranscriptCopy.count
  end

  test "a run of sessions failing alike ends the tick, so a full disk does not mark them all" do
    12.times { archived_session(content: jsonl(1)) }
    TranscriptCopier.any_instance.stubs(:copy).raises(Errno::ENOSPC)

    assert_equal TranscriptCopyJob::MAX_SESSION_FAILURES, TranscriptCopyJob.perform_now[:failed]
    assert_equal TranscriptCopyJob::MAX_SESSION_FAILURES, TranscriptCopyJob.failing.count
  end

  test "a name the store will not take is that session's trouble" do
    archived_session(content: jsonl(1))
    @gcs.refuse = 400

    assert_equal 1, TranscriptCopyJob.perform_now[:failed]
  end

  test "several subagents are one fingerprint, the same in Ruby and in SQL" do
    session = archived_session(content: jsonl(3))
    3.times { |n| add_subagent(session, "sub #{n}\n", agent_id: "agent-#{n}") }

    assert_equal 1, TranscriptCopyJob.perform_now[:copied]
    assert_equal 0, TranscriptCopyJob.candidates(bucket: "zimmer-transcripts").count
    assert_equal 3, TranscriptCopy.sole.subagents.size
  end

  test "an age that is not a number is the default" do
    ENV[TranscriptCopyJob::COPY_AFTER_DAYS_ENV] = "soon"

    assert_equal TranscriptCopyJob::DEFAULT_COPY_AFTER_DAYS, TranscriptCopyJob.copy_after_days
  end
end
