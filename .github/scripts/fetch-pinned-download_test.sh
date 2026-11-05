#!/usr/bin/env bash
# Drives fetch-pinned-download.sh with the real curl against a local server that answers the
# way an upstream outage does, so the retry flags are under test and not just present.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
server_pid=""
trap '[ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null; rm -rf "$tmp"' EXIT

printf 'the pinned bytes\n' >"$tmp/good"
good_sha="$(sha256sum "$tmp/good" | cut -d' ' -f1)"
wrong_sha="$(printf 'other bytes\n' | sha256sum | cut -d' ' -f1)"

# Serves <dir>/good once `failures` requests have failed the way `mode` says: a 504, a socket
# closed with no response, or a 503 asking for a long wait. Both files are re-read on every
# request and every request is logged, so a case can set the outage and count what it caused.
cat >"$tmp/server.py" <<'PY'
import http.server, pathlib, sys
root = pathlib.Path(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with (root / "requests").open("a") as log:
            log.write(self.path + "\n")
        left = int((root / "failures").read_text())
        if left != 0:
            (root / "failures").write_text(str(left - 1))
            mode = (root / "mode").read_text().strip()
            if mode == "drop":
                self.close_connection = True
                self.connection.close()
            elif mode == "retry-after":
                self.send_response(503)
                self.send_header("Retry-After", "3600")
                self.send_header("Content-Length", "0")
                self.end_headers()
            else:
                self.send_error(504)
            return
        body = (root / "good").read_bytes()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(root / "port").write_text(str(server.server_address[1]))
server.serve_forever()
PY
echo 0 >"$tmp/failures"
echo 504 >"$tmp/mode"
python3 -I "$tmp/server.py" "$tmp" &
server_pid=$!
for _ in $(seq 1 50); do
  [ -s "$tmp/port" ] && break
  sleep 0.1
done
url="http://127.0.0.1:$(cat "$tmp/port")/tool.tar.xz"

failed=0
pass() { echo "ok   - $1"; }
fail() {
  echo "FAIL - $1"
  failed=1
}

# Starts a case with an empty cache unless asked to keep it. `failures` of -1 never recovers.
reset() {
  local failures="$1" keep_cache="${2:-}"
  echo "$failures" >"$tmp/failures"
  echo 504 >"$tmp/mode"
  : >"$tmp/requests"
  rm -f "$tmp/dest"
  [ -n "$keep_cache" ] || rm -rf "$tmp/cache"
}

# Two retries (1+2 seconds): long enough to prove the behaviour, short enough to run on every push.
fetch() {
  local out
  out="$(FETCH_RETRIES=2 FETCH_CACHE_DIR="$tmp/cache" \
    bash "$here/fetch-pinned-download.sh" "$url" "$1" "$tmp/dest" 2>&1)"
  rc=$?
  output="$out"
}
requests() { wc -l <"$tmp/requests" | tr -d ' '; }

reset 0
fetch "$good_sha"
if [ "$rc" -eq 0 ] && cmp -s "$tmp/good" "$tmp/dest" && [ -f "$tmp/cache/$good_sha" ]; then
  pass "a cold cache downloads, verifies and caches"
else
  fail "cold download: rc=$rc, $output"
fi

reset 2
fetch "$good_sha"
if [ "$rc" -eq 0 ] && [ "$(requests)" -eq 3 ] && cmp -s "$tmp/good" "$tmp/dest"; then
  pass "two 504s then a 200 succeeds on the third request"
else
  fail "504 blip: rc=$rc, requests=$(requests), $output"
fi

reset -1 keep
fetch "$good_sha"
if [ "$rc" -eq 0 ] && [ "$(requests)" -eq 0 ] && cmp -s "$tmp/good" "$tmp/dest"; then
  pass "a warm cache survives an outage without making a request"
else
  fail "warm cache: rc=$rc, requests=$(requests), $output"
fi

reset -1
fetch "$good_sha"
if [ "$rc" -ne 0 ] && [ "$(requests)" -eq 3 ] && [ ! -e "$tmp/cache/$good_sha" ]; then
  pass "a sustained outage on a cold cache fails, after every retry"
else
  fail "sustained outage: rc=$rc, requests=$(requests), $output"
fi

reset 2
echo drop >"$tmp/mode"
fetch "$good_sha"
if [ "$rc" -eq 0 ] && [ "$(requests)" -eq 3 ] && cmp -s "$tmp/good" "$tmp/dest"; then
  pass "two dropped connections then a 200 succeeds on the third request"
else
  fail "dropped connections: rc=$rc, requests=$(requests), $output"
fi

reset -1
echo retry-after >"$tmp/mode"
FETCH_TIMEOUT=2 fetch "$good_sha"
if [ "$rc" -eq 124 ] && [ "$(requests)" -eq 1 ] && [ ! -e "$tmp/cache/$good_sha" ]; then
  pass "a Retry-After longer than the limit fails at the limit"
else
  fail "Retry-After: rc=$rc, requests=$(requests), $output"
fi

reset 0
fetch "$wrong_sha"
if [ "$rc" -ne 0 ] && [ ! -e "$tmp/dest" ] && [ ! -e "$tmp/cache/$wrong_sha" ] &&
  [[ "$output" == *"::error::"* ]]; then
  pass "a download that does not match the pin fails, and leaves nothing behind"
else
  fail "sha mismatch: rc=$rc, $output"
fi

reset 0
mkdir -p "$tmp/cache"
printf 'tampered\n' >"$tmp/cache/$good_sha"
fetch "$good_sha"
if [ "$rc" -eq 0 ] && [ "$(requests)" -eq 1 ] && cmp -s "$tmp/good" "$tmp/dest" &&
  cmp -s "$tmp/good" "$tmp/cache/$good_sha" && [[ "$output" == *"::warning::"* ]]; then
  pass "a cached copy that does not match is replaced from upstream"
else
  fail "bad cache, good upstream: rc=$rc, requests=$(requests), $output"
fi

reset -1
mkdir -p "$tmp/cache"
printf 'tampered\n' >"$tmp/cache/$good_sha"
fetch "$good_sha"
if [ "$rc" -ne 0 ] && [ ! -e "$tmp/dest" ]; then
  pass "a bad cached copy during an outage fails rather than using it"
else
  fail "bad cache, outage: rc=$rc, $output"
fi

reset 0
: >"$tmp/cache-is-a-file"
out="$(FETCH_RETRIES=2 FETCH_CACHE_DIR="$tmp/cache-is-a-file" \
  bash "$here/fetch-pinned-download.sh" "$url" "$good_sha" "$tmp/dest" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && cmp -s "$tmp/good" "$tmp/dest" && [[ "$out" == *"::warning::"* ]]; then
  pass "a cache that cannot be written is a warning, not a failure"
else
  fail "unwritable cache: rc=$rc, $out"
fi

exit "$failed"
