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
# Do NOT use it for a column that is the only copy of a value. And because it never
# raises, `previous:` schemes and `support_unencrypted_data` have no effect on these
# columns (Rails tries those after a failure): to read an older key, list it in the
# key provider.
class UnreadableTwinAsNil < ActiveRecord::Encryption::Encryptor
  # The app's own key provider, from the default context. An `encryptor:` option makes
  # Rails run every operation in a copy of that context, and a provider built there is
  # thrown away with it, so without this each encrypt and decrypt derives the key again
  # (about 60 ms). Built on first use, so a missing key raises where it is needed.
  module DefaultKeys
    module_function

    def encryption_key = ActiveRecord::Encryption.default_context.key_provider.encryption_key

    def decryption_keys(message) = ActiveRecord::Encryption.default_context.key_provider.decryption_keys(message)
  end

  def decrypt(...)
    super
  rescue ActiveRecord::Encryption::Errors::Decryption
    nil
  end
end
