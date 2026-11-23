# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Upgrade, roll back to a version that knows only the plaintext columns, rotate a
# token there, upgrade again. The row then carries a stale encrypted twin. In this
# (expand) phase every read takes the plaintext, so a stale twin, or one that cannot
# be decrypted at all, must never be served and must never get in the way.
class McpOauthCredentialRollbackTest < ActiveSupport::TestCase
  setup do
    @credential = mcp_oauth_credentials(:notion)
    @credential.update!(access_token: "at-before", refresh_token: "rt-before", client_secret: "cs-before", expires_at: 5.minutes.from_now)
  end

  # What code that has never heard of the twins does to the row.
  def rotate_on_the_rolled_back_version(**values)
    McpOauthCredential.where(id: @credential.id).update_all(values)
    @credential = McpOauthCredential.find(@credential.id)
  end

  def ok_response(body)
    response = Net::HTTPSuccess.new("1.1", "200", "OK")
    response.define_singleton_method(:code) { "200" }
    response.define_singleton_method(:body) { body.to_json }
    response
  end

  test "every read serves the rotated plaintext, not the stale twin" do
    rotate_on_the_rolled_back_version(access_token: "at-rotated", refresh_token: "rt-rotated", client_secret: "cs-rotated")
    assert_equal "at-before", @credential.access_token_ciphertext, "the twin really is stale"

    assert_equal "at-rotated", @credential.access_token
    assert_equal "rt-rotated", @credential.refresh_token
    assert_equal "cs-rotated", @credential.client_secret
    assert_equal %w[at-rotated rt-rotated], McpOauthCredential.where(id: @credential.id).pluck(:access_token, :refresh_token).first
  end

  test "a refresh sends the rotated refresh token and secret" do
    rotate_on_the_rolled_back_version(access_token: "at-rotated", refresh_token: "rt-rotated", client_secret: "cs-rotated")
    sent = stub_token_post(ok_response(access_token: "at-new", expires_in: 3600)) { assert @credential.refresh! }

    assert_equal "rt-rotated", sent[:refresh_token]
    assert_equal "cs-rotated", sent[:client_secret]
    assert_equal "rt-rotated", @credential.reload.refresh_token, "a response that omits it keeps the rotated one"
  end

  test "a token the rolled-back version cleared stays cleared" do
    rotate_on_the_rolled_back_version(refresh_token: nil)
    assert_nil @credential.refresh_token
    refute @credential.can_refresh?
    @credential.update!(scopes: "x")
    assert_nil @credential.reload.refresh_token
  end

  test "an unrelated save never copies a stale twin over the plaintext" do
    rotate_on_the_rolled_back_version(access_token: "at-rotated", refresh_token: "rt-rotated", client_secret: "cs-rotated")
    @credential.update!(scopes: "x")

    assert_equal %w[at-rotated rt-rotated cs-rotated], McpOauthCredential.where(id: @credential.id).pick(:access_token, :refresh_token, :client_secret)
  end

  test "the next write of a token brings its twin back in step, and the mirror does the rest" do
    rotate_on_the_rolled_back_version(access_token: "at-rotated", refresh_token: "rt-rotated", client_secret: "cs-rotated")
    @credential.update!(access_token: "at-newer")
    assert_equal "at-newer", @credential.reload.access_token_ciphertext

    assert @credential.mirror_plaintext_secrets!
    @credential.reload
    assert_equal %w[at-newer rt-rotated cs-rotated], [ @credential.access_token_ciphertext, @credential.refresh_token_ciphertext, @credential.client_secret_ciphertext ]
  end

  # A twin written under another SECRET_KEY_BASE. The documented claim is that this
  # costs nothing while the plaintext is still written.
  def make_twins_undecryptable
    junk = { p: "AAAA", h: { iv: "AAAAAAAAAAAAAAAA", at: "AAAAAAAAAAAAAAAAAAAAAA==" } }.to_json
    # Raw SQL: update_all would encrypt it, under the right key.
    McpOauthCredential.connection.execute(McpOauthCredential.sanitize_sql([
      "UPDATE mcp_oauth_credentials SET access_token_ciphertext = :j, refresh_token_ciphertext = :j, client_secret_ciphertext = :j WHERE id = :id",
      { j: junk, id: @credential.id }
    ]))
    @credential = McpOauthCredential.find(@credential.id)
    assert_nil @credential.access_token_ciphertext
    @credential = McpOauthCredential.find(@credential.id)
  end

  test "an undecryptable twin does not affect reads" do
    make_twins_undecryptable
    assert_equal "at-before", @credential.access_token
    assert @credential.can_refresh?
  end

  test "an undecryptable twin does not stop an unrelated save" do
    make_twins_undecryptable
    @credential.update!(scopes: "x")
    assert_equal "x", @credential.reload.scopes
  end

  test "an undecryptable twin does not lose a token the provider just rotated" do
    make_twins_undecryptable
    stub_token_post(ok_response(access_token: "at-new", refresh_token: "rt-new", expires_in: 3600)) { assert @credential.refresh! }

    assert_equal %w[at-new rt-new], McpOauthCredential.where(id: @credential.id).pick(:access_token, :refresh_token)
  end

  test "an undecryptable twin does not stop the redactor, the mirror or /supervisor's clear" do
    make_twins_undecryptable
    assert_nothing_raised { TranscriptRedactor.reset_known_secrets! }
    @credential.update!(refresh_token: nil)
    assert_nil @credential.reload.refresh_token
    assert_nothing_raised { McpOauthCredential.find(@credential.id).mirror_plaintext_secrets! }
  end

  # --- SECRET_KEY_BASE changed under existing twins ------------------------------
  #
  # The real trigger: twins written under one key, then the process runs with
  # another. Not corrupted bytes, a genuinely valid ciphertext for a different key.
  # It costs nothing in this phase because every read takes the plaintext.

  def change_the_key_under_the_twins
    provider = ActiveRecord::Encryption::DerivedSecretKeyProvider.new("the key this deployment had before")
    encryptor = ActiveRecord::Encryption::Encryptor.new
    { "access_token" => "at-before", "refresh_token" => "rt-before", "client_secret" => "cs-before" }.each do |column, value|
      ciphertext = encryptor.encrypt(value, key_provider: provider)
      assert_equal value, encryptor.decrypt(ciphertext, key_provider: provider), "a valid ciphertext, for the other key"
      McpOauthCredential.connection.execute(McpOauthCredential.sanitize_sql(
        [ "UPDATE mcp_oauth_credentials SET #{column}_ciphertext = ? WHERE id = ?", ciphertext, @credential.id ]
      ))
    end
    assert_nil McpOauthCredential.find(@credential.id).access_token_ciphertext, "unreadable now, and the column is not empty"
    assert raw("access_token_ciphertext").present?
    @credential = McpOauthCredential.find(@credential.id)
  end

  def raw(column) = McpOauthCredential.connection.select_value("SELECT #{column} FROM mcp_oauth_credentials WHERE id = #{@credential.id}")

  test "after the key changed, refresh! succeeds and keeps the refresh token the provider rotated" do
    change_the_key_under_the_twins
    sent = stub_token_post(ok_response(access_token: "at-new", refresh_token: "rt-new", expires_in: 3600)) { assert @credential.refresh! }

    assert_equal %w[rt-before cs-before], sent.values_at(:refresh_token, :client_secret)
    assert_equal %w[at-new rt-new cs-before], %w[access_token refresh_token client_secret].map { |column| raw(column) }
    fresh = McpOauthCredential.find(@credential.id)
    assert_equal %w[at-new rt-new], [ fresh.access_token_ciphertext, fresh.refresh_token_ciphertext ], "re-encrypted under the current key"
    assert fresh.can_refresh?
  end

  test "after the key changed, a second refresh works too" do
    change_the_key_under_the_twins
    2.times do |i|
      stub_token_post(ok_response(access_token: "at-#{i}", refresh_token: "rt-#{i}", expires_in: 3600)) { assert McpOauthCredential.find(@credential.id).refresh! }
    end
    assert_equal "rt-1", raw("refresh_token")
  end

  test "after the key changed, an unrelated save changes no secret and no twin" do
    change_the_key_under_the_twins
    columns = %w[access_token refresh_token client_secret access_token_ciphertext refresh_token_ciphertext client_secret_ciphertext]
    before = columns.map { |column| raw(column) }
    @credential.update!(scopes: "x")
    assert_equal before, columns.map { |column| raw(column) }
  end

  test "after the key changed, clearing a token clears the column and its twin" do
    change_the_key_under_the_twins
    @credential.update!(refresh_token: nil)
    assert_nil raw("refresh_token")
    assert_nil raw("refresh_token_ciphertext")
  end

  test "after the key changed, assigning the same token still replaces the unreadable twin" do
    change_the_key_under_the_twins
    @credential.update!(access_token: "at-before")
    assert_equal "at-before", McpOauthCredential.find(@credential.id).access_token_ciphertext
    assert_equal "at-before", raw("access_token")
  end

  test "after the key changed, the mirror re-encrypts every twin, without touching plaintext" do
    change_the_key_under_the_twins
    assert @credential.mirror_plaintext_secrets!

    fresh = McpOauthCredential.find(@credential.id)
    assert_equal %w[at-before rt-before cs-before], [ fresh.access_token_ciphertext, fresh.refresh_token_ciphertext, fresh.client_secret_ciphertext ]
    assert_equal %w[at-before rt-before cs-before], %w[access_token refresh_token client_secret].map { |column| raw(column) }
    refute fresh.mirror_plaintext_secrets!, "nothing left to do"
  end

  # The task picks rows with a missing twin. One such row may hold others written
  # under the old key, and it must re-encrypt them rather than raise and stop the sweep.
  test "after the key changed, the backfill re-encrypts a row it picks instead of raising" do
    change_the_key_under_the_twins
    McpOauthCredential.connection.execute("UPDATE mcp_oauth_credentials SET client_secret_ciphertext = NULL WHERE id = #{@credential.id}")
    entry = PostDeployTask::Registry.all.find { |e| e.task_name == "EncryptMcpOauthCredentialSecrets" }
    run = PostDeployTaskRun.create!(version: "#{entry.version}-#{SecureRandom.hex(4)}", name: entry.task_name, status: "pending")
    assert run.claim!(owner: "test")

    assert_nil entry.task_class.new(run: run, logger: Rails.logger).up

    assert_equal 0, entry.task_class.candidates.count
    fresh = McpOauthCredential.find(@credential.id)
    assert_equal %w[at-before rt-before cs-before], [ fresh.access_token_ciphertext, fresh.refresh_token_ciphertext, fresh.client_secret_ciphertext ]
  end

  test "after the key changed, the refresh job keeps the credential working" do
    change_the_key_under_the_twins
    McpOauthCredential.where.not(id: @credential.id).update_all(refresh_token: nil)
    McpOauthCredential.where(id: @credential.id).update_all(updated_at: 5.hours.ago)
    stub_token_post(ok_response(access_token: "at-new", refresh_token: "rt-new", expires_in: 3600)) { RefreshMcpOauthTokensJob.perform_now }
    assert_equal "rt-new", raw("refresh_token")
  end

  # --- only a decryption failure is forgiven ---------------------------------------

  test "a readable twin is never discarded" do
    before = raw("access_token_ciphertext")
    @credential.update!(access_token: "at-before")
    assert_equal before, raw("access_token_ciphertext"), "an unchanged value writes nothing"
  end

  test "an error that is not a decryption failure is not swallowed" do
    ActiveRecord::Encryption::Cipher.any_instance.stubs(:decrypt).raises(RuntimeError, "something else")
    assert_raises(RuntimeError) { McpOauthCredential.find(@credential.id).access_token_ciphertext }
  end

  test "a missing encryption key is a configuration fault, not an unreadable twin" do
    ActiveRecord::Encryption::Cipher.any_instance.stubs(:decrypt).raises(ActiveRecord::Encryption::Errors::Configuration, "no key")
    assert_raises(ActiveRecord::Encryption::Errors::Configuration) { McpOauthCredential.find(@credential.id).access_token_ciphertext }
    assert_raises(ActiveRecord::Encryption::Errors::Configuration) { McpOauthCredential.find(@credential.id).mirror_plaintext_secrets! }
  end

  # A column that is the only copy of a value must still raise.
  test "the broker's own encrypted columns are not tolerant" do
    grant = McpBrokerGrant.create!(authorization_server: "https://strad.example.com", token_endpoint: "https://strad.example.com/t",
      resource: "https://strad.example.com/mcp", client_id: "c", access_token: "a", refresh_token: "r")
    other = ActiveRecord::Encryption::Encryptor.new.encrypt("a", key_provider: ActiveRecord::Encryption::DerivedSecretKeyProvider.new("other"))
    McpBrokerGrant.connection.execute(McpBrokerGrant.sanitize_sql([ "UPDATE mcp_broker_grants SET access_token = ? WHERE id = ?", other, grant.id ]))
    assert_raises(ActiveRecord::Encryption::Errors::Decryption) { McpBrokerGrant.find(grant.id).access_token }
  end

  # --- a save that fails must fail as itself, and a retry must really write ----------
  #
  # Rails reads every attribute when it restores a rolled-back record.

  test "after the key changed, an invalid edit returns false with its errors" do
    change_the_key_under_the_twins
    refute @credential.update(server_name: "")
    assert_includes @credential.errors[:server_name], "can't be blank"
  end

  test "after the key changed, database and readonly errors keep their class" do
    change_the_key_under_the_twins
    other = McpOauthCredential.where.not(id: @credential.id).first
    assert_raises(ActiveRecord::RecordNotUnique) do
      McpOauthCredential.transaction(requires_new: true) { @credential.tap { |c| c.credential_key = other.credential_key }.save!(validate: false) }
    end
    assert_raises(ActiveRecord::ReadOnlyRecord) { McpOauthCredential.find(@credential.id).tap(&:readonly!).update!(scopes: "x") }
    assert_raises(ActiveRecord::Deadlocked) { McpOauthCredential.find(@credential.id).with_lock { raise ActiveRecord::Deadlocked, "d" } }
  end

  test "after the key changed, clearing a secret clears its twin even when the first attempt failed" do
    change_the_key_under_the_twins
    refute @credential.update(server_name: "", access_token: "B", refresh_token: "R2", client_secret: nil)
    @credential.update!(server_name: "s2")

    assert_equal [ "B", "R2", nil, nil ], [ raw("access_token"), raw("refresh_token"), raw("client_secret"), raw("client_secret_ciphertext") ]
  end

  test "after the key changed, inspecting, copying and serializing the record do not raise" do
    change_the_key_under_the_twins
    [ :inspect, :as_json, :dup, :clone, :attributes ].each { |m| assert_nothing_raised { McpOauthCredential.find(@credential.id).public_send(m) } }
    assert_nothing_raised { Marshal.load(Marshal.dump(McpOauthCredential.find(@credential.id))) }
  end

  test "a secret the rolled-back version cleared leaves no twin behind after the next save, readable or not" do
    rotate_on_the_rolled_back_version(refresh_token: nil)
    assert raw("refresh_token_ciphertext").present?
    @credential.update!(scopes: "x")
    assert_nil raw("refresh_token_ciphertext"), "or the contract phase would bring a cleared token back"
  end

  test "the mirror clears the twin of a cleared secret" do
    rotate_on_the_rolled_back_version(refresh_token: nil)
    assert @credential.mirror_plaintext_secrets!
    assert_nil raw("refresh_token_ciphertext")
    assert_equal "at-before", McpOauthCredential.find(@credential.id).access_token_ciphertext
  end

  test "a record loaded without its twins can still be saved" do
    partial = McpOauthCredential.select(:id, :server_name, :server_url, :credential_key, :client_id, :access_token, :token_endpoint, :scopes, :updated_at).find(@credential.id)
    assert_nothing_raised { partial.update!(scopes: "z") }
    assert_equal %w[at-before rt-before z], [ raw("access_token"), raw("refresh_token"), raw("scopes") ]
  end

  test "a save that validation refuses is still refused" do
    change_the_key_under_the_twins
    assert_raises(ActiveRecord::RecordInvalid) { @credential.update!(access_token: "") }
    assert_raises(ActiveRecord::RecordInvalid) { McpOauthCredential.find(@credential.id).update!(token_endpoint: "http://insecure.example.com/token") }
    assert_equal "at-before", raw("access_token")
  end
end

# Real transactions: inside the test suite's own one, a rollback is to a savepoint,
# and Rails loses a retry on the same object there whatever the twins hold.
class McpOauthCredentialRolledBackSaveTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @credential = McpOauthCredential.create!(server_name: "rolled-back", server_url: "https://rolled-back.example.com/mcp",
      credential_key: "rolled-back|#{SecureRandom.hex(4)}", client_id: "c", access_token: "A", refresh_token: "R", client_secret: "S",
      token_endpoint: "https://rolled-back.example.com/token")
  end

  teardown { McpOauthCredential.where(server_name: "rolled-back").delete_all }

  def raw(column) = McpOauthCredential.connection.select_value("SELECT #{column} FROM mcp_oauth_credentials WHERE id = #{@credential.id}")

  def make_unreadable
    provider = ActiveRecord::Encryption::DerivedSecretKeyProvider.new("the key this deployment had before")
    McpOauthCredential::SECRET_COLUMNS.each do |column|
      ciphertext = ActiveRecord::Encryption::Encryptor.new.encrypt("x", key_provider: provider)
      McpOauthCredential.connection.execute(McpOauthCredential.sanitize_sql([ "UPDATE mcp_oauth_credentials SET #{column}_ciphertext = ? WHERE id = ?", ciphertext, @credential.id ]))
    end
    @credential = McpOauthCredential.find(@credential.id)
  end

  # The readable case is the control: an unreadable twin must behave the same.
  { "readable" => false, "unreadable" => true }.each do |label, unreadable|
    test "#{label} twins: a rolled-back save raises its own error, and a retry that returns true has written" do
      make_unreadable if unreadable
      error = assert_raises(RuntimeError) { McpOauthCredential.transaction { @credential.update!(access_token: "B"); raise "orig" } }
      assert_equal "orig", error.message
      assert_equal "A", raw("access_token")

      assert @credential.update(access_token: "B")
      assert_equal "B", raw("access_token")
      assert_equal "B", McpOauthCredential.find(@credential.id).access_token_ciphertext
    end

    test "#{label} twins: after a rolled-back save of something else, a later token is written" do
      make_unreadable if unreadable
      McpOauthCredential.transaction { @credential.update!(scopes: "x"); raise ActiveRecord::Rollback }
      @credential.update!(access_token: "B", scopes: "y")
      assert_equal %w[B y], [ raw("access_token"), raw("scopes") ]
    end

    test "#{label} twins: a token cleared in a rolled-back save and cleared again leaves no twin" do
      make_unreadable if unreadable
      McpOauthCredential.transaction { @credential.update!(refresh_token: nil); raise ActiveRecord::Rollback }
      assert_equal "R", raw("refresh_token")
      @credential.update!(refresh_token: nil)
      assert_equal [ nil, nil ], [ raw("refresh_token"), raw("refresh_token_ciphertext") ]
    end

    test "#{label} twins: a rolled-back mirror can be run again on the same object" do
      unreadable ? make_unreadable : McpOauthCredential.where(id: @credential.id).update_all(access_token: "A2")
      @credential = McpOauthCredential.find(@credential.id)
      McpOauthCredential.transaction { @credential.mirror_plaintext_secrets!; raise ActiveRecord::Rollback }
      assert @credential.mirror_plaintext_secrets!
      assert_equal raw("access_token"), McpOauthCredential.find(@credential.id).access_token_ciphertext
    end
  end
end
