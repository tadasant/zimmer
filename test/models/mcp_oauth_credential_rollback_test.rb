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
    assert_raises(ActiveRecord::Encryption::Errors::Base) { @credential.access_token_ciphertext }
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
    assert_raises(ActiveRecord::Encryption::Errors::Decryption) { McpOauthCredential.find(@credential.id).access_token_ciphertext }
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
    @credential.stubs(:read_attribute).with("access_token_ciphertext").raises(ActiveRecord::StatementInvalid, "db")
    assert_raises(ActiveRecord::StatementInvalid) { @credential.access_token = "x" }
  end

  test "a missing encryption key is a configuration fault, not an unreadable twin" do
    @credential.stubs(:read_attribute).with("access_token_ciphertext").raises(ActiveRecord::Encryption::Errors::Configuration, "no key")
    assert_raises(ActiveRecord::Encryption::Errors::Configuration) { @credential.access_token = "x" }
  end

  test "the mirror does not swallow anything else either" do
    @credential.stubs(:read_attribute).with("access_token").returns("at-before")
    @credential.stubs(:read_attribute).with("access_token_ciphertext").raises(ActiveRecord::Encryption::Errors::Configuration, "no key").then.returns(nil)
    assert_raises(ActiveRecord::Encryption::Errors::Configuration) { @credential.mirror_plaintext_secrets! }
  end

  test "a save that validation refuses is still refused" do
    change_the_key_under_the_twins
    assert_raises(ActiveRecord::RecordInvalid) { @credential.update!(access_token: "") }
    assert_raises(ActiveRecord::RecordInvalid) { McpOauthCredential.find(@credential.id).update!(token_endpoint: "http://insecure.example.com/token") }
    assert_equal "at-before", raw("access_token")
  end
end
