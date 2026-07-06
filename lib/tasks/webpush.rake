namespace :webpush do
  desc "Generate VAPID keys for Web Push notifications"
  task generate_keys: :environment do
    require "web-push"

    puts "=" * 80
    puts "VAPID Key Generation for Web Push Notifications"
    puts "=" * 80
    puts

    # Generate new VAPID key pair
    vapid_key = WebPush.generate_key

    puts "Generated VAPID keys:"
    puts
    puts "Public Key (safe to share with clients):"
    puts vapid_key.public_key
    puts
    puts "Private Key (keep secret, store in credentials):"
    puts vapid_key.private_key
    puts
    puts "=" * 80
    puts "Next Steps:"
    puts "=" * 80
    puts
    puts "Add these keys to your Rails credentials:"
    puts
    puts "  bin/rails credentials:edit"
    puts
    puts "Add the following YAML:"
    puts
    puts "  webpush:"
    puts "    public_key: #{vapid_key.public_key}"
    puts "    private_key: #{vapid_key.private_key}"
    puts "    subject: mailto:admin@yourdomain.com"
    puts
    puts "Replace 'admin@yourdomain.com' with your contact email."
    puts
    puts "=" * 80
  end
end
