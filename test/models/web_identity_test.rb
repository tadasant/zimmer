# frozen_string_literal: true

require "test_helper"

class WebIdentityTest < ActiveSupport::TestCase
  def google_identity(sub: "sub-1", email: "tadas@tadasant.com")
    WebAuth::GoogleOauth::Identity.new(sub: sub, email: email, hosted_domain: "tadasant.com", name: "Tadas")
  end

  def enrolled_identity(at: Time.current)
    identity = WebIdentity.sign_in_from_google!(google_identity)
    secret = identity.pending_totp_secret!
    codes = identity.confirm_totp_enrollment!(WebAuth::Totp.code_at(secret, at), at: at)
    [ identity, secret, codes ]
  end

  test "sign-in is keyed on Google's account id, and keeps the row current" do
    first = WebIdentity.sign_in_from_google!(google_identity)
    again = WebIdentity.sign_in_from_google!(google_identity(email: "renamed@tadasant.com"))

    assert_equal first.id, again.id
    assert_equal "renamed@tadasant.com", again.email
    assert_not_equal first.id, WebIdentity.sign_in_from_google!(google_identity(sub: "sub-2")).id
  end

  test "enrollment needs a code from the pending secret, then issues ten recovery codes" do
    identity = WebIdentity.sign_in_from_google!(google_identity)
    secret = identity.pending_totp_secret!
    assert_equal secret, identity.pending_totp_secret!, "a reload of the setup page must keep the same key"

    assert_nil identity.confirm_totp_enrollment!("000000") unless WebAuth::Totp.code_at(secret, Time.current) == "000000"
    refute_predicate identity.reload, :totp_enrolled?

    codes = identity.confirm_totp_enrollment!(WebAuth::Totp.code_at(secret, Time.current))
    assert_equal 10, codes.size
    assert_predicate identity.reload, :totp_enrolled?
    assert_equal secret, identity.totp_secret
    assert_nil identity.totp_pending_secret
    assert_equal 10, identity.recovery_codes_remaining
    codes.each { |code| refute_includes identity.recovery_code_digests, code, "plain codes must not be stored" }
  end

  test "an authenticator code is accepted once" do
    identity, secret, = enrolled_identity(at: 2.minutes.ago)
    now = Time.current

    assert_equal :totp, identity.verify_second_factor!(WebAuth::Totp.code_at(secret, now), at: now)
    assert_equal :invalid, identity.verify_second_factor!(WebAuth::Totp.code_at(secret, now), at: now)
  end

  test "a recovery code works once, in any case and with or without its dashes" do
    identity, _secret, codes = enrolled_identity

    assert_equal :recovery_code, identity.verify_second_factor!(codes.first.upcase.delete("-"))
    assert_equal 9, identity.reload.recovery_codes_remaining
    assert_equal :invalid, identity.verify_second_factor!(codes.first)
  end

  test "five wrong codes lock the second factor for fifteen minutes, right codes included" do
    identity, secret, = enrolled_identity(at: 5.minutes.ago)
    now = Time.current

    4.times { assert_equal :invalid, identity.verify_second_factor!("000000", at: now) }
    assert_equal :invalid, identity.verify_second_factor!("000000", at: now)
    assert_equal :locked, identity.verify_second_factor!(WebAuth::Totp.code_at(secret, now), at: now)

    later = now + WebIdentity::LOCKOUT + 1.second
    assert_equal :totp, identity.verify_second_factor!(WebAuth::Totp.code_at(secret, later), at: later)
  end

  test "an enrollment confirmed before the deployment's reset instant does not count" do
    identity, = enrolled_identity(at: 2.days.ago)

    assert identity.totp_enrolled?(reset_before: 3.days.ago)
    refute identity.totp_enrolled?(reset_before: 1.day.ago)
  end

  test "a replacement authenticator leaves the old one working until it is confirmed" do
    identity, old_secret, = enrolled_identity(at: 2.minutes.ago)
    new_secret = identity.pending_totp_secret!

    assert_equal old_secret, identity.reload.totp_secret
    assert identity.totp_enrolled?

    identity.confirm_totp_enrollment!(WebAuth::Totp.code_at(new_secret, Time.current))
    assert_equal new_secret, identity.reload.totp_secret
  end

  test "lockouts escalate, and only a right answer clears the count" do
    identity, secret, = enrolled_identity(at: 1.hour.ago)
    now = Time.current

    5.times { identity.verify_second_factor!("000000", at: now) }
    assert_in_delta now + 15.minutes, identity.reload.second_factor_locked_until, 1

    now += 16.minutes
    5.times { identity.verify_second_factor!("000000", at: now) }
    assert_in_delta now + 30.minutes, identity.reload.second_factor_locked_until, 1

    now += 31.minutes
    assert_equal :totp, identity.verify_second_factor!(WebAuth::Totp.code_at(secret, now), at: now)
    assert_equal 0, identity.reload.second_factor_failed_attempts
    assert_equal 1.day, identity.lockout_after(500)
  end

  test "confirming a new authenticator signs out everywhere" do
    identity, = enrolled_identity(at: 2.minutes.ago)
    generation = identity.session_generation
    secret = identity.pending_totp_secret!

    identity.confirm_totp_enrollment!(WebAuth::Totp.code_at(secret, Time.current))
    assert_equal generation + 1, identity.reload.session_generation
  end
end
