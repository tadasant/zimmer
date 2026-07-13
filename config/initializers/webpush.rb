# Webpush configuration for PWA push notifications
#
# VAPID keys must be added to Rails credentials:
#   bin/rails webpush:generate_keys  # Generate new keys
#   bin/rails credentials:edit       # Add keys to credentials
#
# Expected credentials format:
#   webpush:
#     public_key: <base64url-encoded public key>
#     private_key: <base64url-encoded private key>
#     subject: mailto:admin@yourdomain.com

module WebpushConfig
  class << self
    def public_key
      Rails.application.credentials.dig(:webpush, :public_key)
    end

    def private_key
      Rails.application.credentials.dig(:webpush, :private_key)
    end

    def subject
      Rails.application.credentials.dig(:webpush, :subject)
    end

    def configured?
      public_key.present? && private_key.present?
    end

    def vapid_keys
      return nil unless configured?

      {
        public_key: public_key,
        private_key: private_key,
        subject: subject || "mailto:admin@zimmer.local"
      }
    end
  end
end
