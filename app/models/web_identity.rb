# frozen_string_literal: true

# Someone who has signed in to the web UI with Google, and their second factor.
#
# Rows are created by WebAuth sign-in, keyed on Google's stable account id
# (`sub`), never on the email: an address can be renamed or recycled, and a
# recycled one must not inherit somebody else's authenticator.
#
# This is not the User roster. User names the humans Zimmer attributes words
# to; WebIdentity records who proved they could reach the browser. The two are
# deliberately not joined here.
#
# The TOTP secret is stored as plain text, like every other credential in this
# database (see "Nothing is encrypted at rest" in docs/auth/overview.md). The
# recovery codes are stored only as SHA-256 digests: they are 50 random bits
# each, so a fast hash is enough, and a code is shown once and never again.
class WebIdentity < ApplicationRecord
  RECOVERY_CODE_COUNT = 10
  # Every this-many consecutive wrong codes, the second factor locks.
  MAX_FAILED_ATTEMPTS = 5
  # The first lockout. Each one after it doubles, up to MAX_LOCKOUT, and the
  # count only clears on a right answer, so slow guessing gets slower.
  LOCKOUT = 15.minutes
  MAX_LOCKOUT = 1.day

  after_destroy_commit :disconnect_cable_connections

  validates :google_sub, presence: true, uniqueness: true
  validates :email, presence: true
  validates :hosted_domain, presence: true

  # @param identity [WebAuth::GoogleOauth::Identity]
  # @return [WebIdentity]
  def self.sign_in_from_google!(identity, at: Time.current)
    attempts = 0
    begin
      record = find_or_initialize_by(google_sub: identity.sub)
      record.email = identity.email
      record.hosted_domain = identity.hosted_domain
      record.name = identity.name if identity.name.present?
      record.last_signed_in_at = at
      record.save!
      record
    rescue ActiveRecord::RecordNotUnique
      # Two first sign-ins raced to create the row; the loser finds it.
      attempts += 1
      retry if attempts == 1
      raise
    end
  end

  def display_name = name.presence || email

  # Whether a confirmed authenticator stands. An enrollment confirmed before the
  # deployment's reset instant does not.
  def totp_enrolled?(reset_before: nil)
    return false if totp_enrolled_at.nil? || totp_secret.blank?

    reset_before.nil? || totp_enrolled_at >= reset_before
  end

  # The secret the setup page shows. Kept apart from `totp_secret`, so an
  # authenticator being replaced keeps working until the new one is confirmed.
  # Reused across reloads of the setup page, so the key a person has already
  # typed into their app stays the one Zimmer expects.
  def pending_totp_secret!
    update!(totp_pending_secret: WebAuth::Totp.generate_secret) if totp_pending_secret.blank?
    totp_pending_secret
  end

  # Confirm the pending secret with a code from the app. It replaces any
  # previous authenticator, issues a new set of recovery codes, and signs the
  # identity out everywhere: someone replacing an authenticator may be doing it
  # because the old one was compromised. The caller re-signs-in the browser
  # that confirmed.
  #
  # @return [Array<String>, nil] the new recovery codes, in plain text, or nil
  #   if the code was wrong
  def confirm_totp_enrollment!(code, at: Time.current)
    return nil if totp_pending_secret.blank?

    step = WebAuth::Totp.matching_step(totp_pending_secret, code, at: at)
    return nil if step.nil?

    codes = Array.new(RECOVERY_CODE_COUNT) { self.class.generate_recovery_code }
    update!(
      totp_secret: totp_pending_secret,
      totp_pending_secret: nil,
      totp_enrolled_at: at,
      totp_last_used_step: step,
      recovery_code_digests: codes.map { |c| self.class.digest_recovery_code(c) },
      second_factor_failed_attempts: 0,
      second_factor_locked_until: nil,
      session_generation: session_generation + 1
    )
    disconnect_cable_connections
    codes
  end

  def second_factor_locked?(at: Time.current)
    second_factor_locked_until.present? && second_factor_locked_until > at
  end

  # Check an authenticator code or a recovery code. A recovery code is spent by
  # using it. Every wrong answer counts towards the lockout, and a locked
  # identity accepts nothing until the lockout passes.
  #
  # @return [Symbol] :totp, :recovery_code, :invalid or :locked
  def verify_second_factor!(input, at: Time.current)
    with_lock do
      if second_factor_locked?(at: at)
        :locked
      elsif (step = WebAuth::Totp.matching_step(totp_secret, input, at: at, after_step: totp_last_used_step))
        update!(totp_last_used_step: step, second_factor_failed_attempts: 0, second_factor_locked_until: nil)
        :totp
      elsif (digest = self.class.digest_recovery_code(input)) && recovery_code_digests.include?(digest)
        update!(recovery_code_digests: recovery_code_digests - [ digest ], second_factor_failed_attempts: 0, second_factor_locked_until: nil)
        :recovery_code
      else
        failures = second_factor_failed_attempts + 1
        locked_until = (at + lockout_after(failures) if (failures % MAX_FAILED_ATTEMPTS).zero?)
        update!(second_factor_failed_attempts: failures, second_factor_locked_until: locked_until || second_factor_locked_until)
        if locked_until
          Rails.logger.warn("[web_auth] second factor for #{email} locked until #{locked_until.utc.iso8601} after #{failures} wrong codes in a row")
        end
        :invalid
      end
    end
  end

  def recovery_codes_remaining = recovery_code_digests.size

  # Ends every signed-in browser for this identity at its next request, voids
  # its trusted browsers, and closes its open live-update connections now.
  def sign_out_everywhere!
    increment!(:session_generation)
    disconnect_cable_connections
  end

  # 15 minutes, then 30, 60, … up to a day.
  def lockout_after(failures)
    [ LOCKOUT * (2**((failures / MAX_FAILED_ATTEMPTS) - 1)), MAX_LOCKOUT ].min
  end

  # A connection is checked only when it opens, so one already open would keep
  # receiving Turbo Streams after its browser stopped counting as signed in.
  def disconnect_cable_connections
    ActionCable.server.remote_connections.where(web_identity: self).disconnect
  rescue StandardError => e
    Rails.logger.warn("[web_auth] could not disconnect live connections for web_identity_id=#{id}: #{e.class}: #{e.message}")
  end

  # Ten characters of base32, grouped for reading aloud: "k7qd-m2xa-pf".
  def self.generate_recovery_code
    WebAuth::Totp.base32_encode(SecureRandom.random_bytes(7))[0, 10].downcase.scan(/.{1,4}/).join("-")
  end

  # Case, spaces and dashes do not matter to someone typing a code back in.
  def self.digest_recovery_code(code)
    normalized = code.to_s.downcase.gsub(/[^a-z2-7]/, "")
    return nil unless normalized.length == 10

    Digest::SHA256.hexdigest(normalized)
  end
end
