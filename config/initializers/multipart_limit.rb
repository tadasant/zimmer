# Force `Rack::Multipart` to load eagerly at boot. Rack registers it via
# `autoload`, so the constant is only defined the first time a request triggers
# multipart parsing. Under Rails' parallel test workers a request can reference
# the not-yet-loaded constant and raise `NameError: uninitialized constant
# Rack::Multipart` (an order-dependent flake that surfaces on whichever shard
# happens to dispatch a multipart upload first — e.g. sessions_controller_test's
# attachment tests). Requiring it here resolves the constant deterministically
# before any worker forks, and is harmless in every other environment.
require "rack/multipart"

# Rack rejects multipart bodies with more parts than `multipart_part_limit`
# (default 128) as a defense against DoS via massive form uploads. The
# file-attachment UI now allows up to 200 files per request, so we raise the
# limit with headroom above that. The complementary `multipart_total_part_limit`
# (default 4096) already comfortably exceeds 200, so no change is needed there.
Rack::Utils.multipart_part_limit = 250
