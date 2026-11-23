# frozen_string_literal: true

# An Active Record encryptor for a column that only duplicates another one: a value
# that cannot be decrypted reads as nil instead of raising.
#
# For McpOauthCredential's encrypted twins, and only while the plaintext columns are
# what every read uses. Rails decrypts a stored value not only to read it but to
# compare it on assignment, before a save and when restoring a rolled-back record, so
# a twin written under another SECRET_KEY_BASE would otherwise make those raise: a
# token the provider had just rotated could not be stored, and the real error of a
# failed save was replaced by a decryption error.
#
# Only Errors::Decryption, which is what a wrong key or damaged ciphertext raises. A
# missing key is a configuration fault and still raises.
#
# Do NOT use it for a column that is the only copy of a value.
class UnreadableTwinAsNil < ActiveRecord::Encryption::Encryptor
  def decrypt(...)
    super
  rescue ActiveRecord::Encryption::Errors::Decryption
    nil
  end
end
