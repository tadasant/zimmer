# frozen_string_literal: true

require "test_helper"

class WebAuth::TotpTest < ActiveSupport::TestCase
  # RFC 4226 Appendix D: HOTP values for the ASCII secret "12345678901234567890".
  # TOTP is HOTP over the time step, so these pin the HMAC and the truncation.
  RFC_SECRET = WebAuth::Totp.base32_encode("12345678901234567890")
  RFC_4226_CODES = %w[755224 287082 359152 969429 338314 254676 287922 162583 399871 520489].freeze

  test "matches the RFC 4226 test vectors" do
    RFC_4226_CODES.each_with_index do |code, counter|
      assert_equal code, WebAuth::Totp.code_for_step(RFC_SECRET, counter), "counter #{counter}"
    end
  end

  test "matches the RFC 6238 SHA-1 vectors, truncated to six digits" do
    { 59 => "287082", 1_111_111_109 => "081804", 1_234_567_890 => "005924", 2_000_000_000 => "279037" }.each do |time, code|
      assert_equal code, WebAuth::Totp.code_at(RFC_SECRET, Time.at(time)), "t=#{time}"
    end
  end

  test "base32 round-trips, ignoring case and spaces" do
    bytes = SecureRandom.random_bytes(20)
    encoded = WebAuth::Totp.base32_encode(bytes)
    assert_equal bytes, WebAuth::Totp.base32_decode(encoded.downcase.scan(/.{4}/).join(" "))
  end

  test "accepts the current step and one either side, and nothing further" do
    secret = WebAuth::Totp.generate_secret
    now = Time.utc(2026, 10, 7, 12, 0, 15)
    step = WebAuth::Totp.step_at(now)

    [ -1, 0, 1 ].each do |offset|
      assert_equal step + offset, WebAuth::Totp.matching_step(secret, WebAuth::Totp.code_for_step(secret, step + offset), at: now)
    end
    [ -2, 2 ].each do |offset|
      assert_nil WebAuth::Totp.matching_step(secret, WebAuth::Totp.code_for_step(secret, step + offset), at: now)
    end
  end

  test "refuses a step at or before the last one used, so a code cannot be replayed" do
    secret = WebAuth::Totp.generate_secret
    now = Time.current
    code = WebAuth::Totp.code_at(secret, now)
    step = WebAuth::Totp.step_at(now)

    assert_nil WebAuth::Totp.matching_step(secret, code, at: now, after_step: step)
    assert_equal step, WebAuth::Totp.matching_step(secret, code, at: now, after_step: step - 1)
  end

  test "refuses anything that is not six digits" do
    secret = WebAuth::Totp.generate_secret
    [ nil, "", "12345", "1234567", "abcdef" ].each do |input|
      assert_nil WebAuth::Totp.matching_step(secret, input)
    end
  end

  test "the provisioning URI is one an authenticator app reads" do
    uri = WebAuth::Totp.provisioning_uri("JBSWY3DPEHPK3PXP", account: "tadas@tadasant.com", issuer: "Zimmer")
    assert_equal "otpauth://totp/Zimmer%3Atadas%40tadasant.com?secret=JBSWY3DPEHPK3PXP&issuer=Zimmer&algorithm=SHA1&digits=6&period=30", uri
  end
end
