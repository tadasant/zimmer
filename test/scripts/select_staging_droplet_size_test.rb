# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"
require "json"
require "yaml"

# Two failure shapes matter here and they pull in opposite directions. Asking for a size
# the region is not selling fails the deploy and pages #alerts. Asking a droplet that
# already exists for a DIFFERENT size resizes it in place -- a power-off and a one-way disk
# growth -- which is worse than the page. So every branch is driven with `terraform` and
# `curl` stubbed on PATH, and the wiring that makes the answer count is asserted too.
class SelectStagingDropletSizeTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("scripts", "select-staging-droplet-size.sh")
  WORKFLOW = Rails.root.join(".github/workflows/deploy-staging.yml")
  TFVARS = Rails.root.join("infra/terraform/staging.tfvars.example")

  FALLBACKS = "s-2vcpu-4gb-amd s-2vcpu-4gb-intel s-2vcpu-4gb-120gb-intel"
  TOKEN = "do-token-under-test"
  DROPLET_PATH = "/v2/droplets/4242"

  # The rows as DigitalOcean's catalog read them on 2026-11-23 at 18:48 UTC, five minutes
  # after it refused s-2vcpu-4gb in nyc3 -- the region lists are the real ones.
  AMD_REGIONS = %w[ams3 blr1 fra1 lon1 nyc1 nyc2 nyc3 sfo3 sgp1 syd1 tor1].freeze
  INTEL_REGIONS = %w[ams3 blr1 fra1 lon1 nyc1 nyc2 nyc3 sfo2 sfo3 sgp1 syd1 tor1].freeze
  REFUSED_REGIONS = %w[ams3 blr1 fra1 lon1 nyc2 sfo2 sfo3 sgp1 syd1 tor1].freeze
  CATALOG = [
    { "slug" => "s-2vcpu-4gb", "memory" => 4096, "available" => true, "regions" => REFUSED_REGIONS },
    { "slug" => "s-2vcpu-4gb-amd", "memory" => 4096, "available" => true, "regions" => AMD_REGIONS },
    { "slug" => "s-2vcpu-4gb-intel", "memory" => 4096, "available" => true, "regions" => INTEL_REGIONS },
    { "slug" => "s-2vcpu-4gb-120gb-intel", "memory" => 4096, "available" => true, "regions" => INTEL_REGIONS },
    { "slug" => "s-2vcpu-2gb-amd", "memory" => 2048, "available" => true, "regions" => AMD_REGIONS },
    { "slug" => "s-4vcpu-8gb", "memory" => 8192, "available" => true, "regions" => REFUSED_REGIONS }
  ].freeze

  # The catalog with each named size sold (or not) in nyc3, and the rest as read.
  def catalog(sold: [], unsold: [], retired: [], unavailable: [])
    CATALOG.map(&:deep_dup).reject { |s| retired.include?(s["slug"]) }.each do |s|
      s["regions"] |= [ "nyc3" ] if sold.include?(s["slug"])
      s["regions"] -= [ "nyc3" ] if unsold.include?(s["slug"])
      s["available"] = false if unavailable.include?(s["slug"])
    end
  end

  def all_4gb = %w[s-2vcpu-4gb] + FALLBACKS.split

  def state(droplet: nil, tainted: false)
    resources = [ { "address" => "digitalocean_reserved_ip.zimmer", "values" => { "id" => "ip" } } ]
    if droplet
      row = { "address" => "digitalocean_droplet.zimmer", "values" => { "id" => "4242", "size" => droplet } }
      row["tainted"] = true if tainted
      resources << row
    end
    JSON.dump("format_version" => "1.0", "values" => { "root_module" => { "resources" => resources } })
  end

  NEVER_APPLIED = JSON.dump("format_version" => "1.0")

  def stub_bin(dir)
    File.write(File.join(dir, "terraform"), <<~SH)
      #!/bin/sh
      [ "$TF_FAIL" = "1" ] && { echo "Error: Failed to load state" >&2; exit 1; }
      [ "$*" = "show -json" ] || { echo "unexpected: terraform $*" >&2; exit 9; }
      cat "$TF_STATE_FILE"
    SH
    # Serves $RESPONSES/<path with / ? & = flattened>: line 1 is the status, the rest the body.
    File.write(File.join(dir, "curl"), <<~SH)
      #!/bin/sh
      out=""; take=""; url=""
      for a in "$@"; do
        case "$take" in
          out) out="$a"; take=""; continue ;;
          hdr) cat "${a#@}" >> "$RESPONSES/headers"; echo >> "$RESPONSES/headers"; take=""; continue ;;
        esac
        case "$a" in -o) take=out ;; -H) take=hdr ;; esac
        url="$a"
      done
      echo "$*" >> "$RESPONSES/argv"
      path="${url#https://api.example}"
      echo "$path" >> "$RESPONSES/calls"
      f="$RESPONSES/$(printf '%s' "$path" | tr '/?&=' '____')"
      if [ ! -f "$f" ]; then printf 000; exit 7; fi
      tail -n +2 "$f" > "$out"
      printf '%s' "$(head -n 1 "$f")"
    SH
    %w[terraform curl].each { |n| File.chmod(0o755, File.join(dir, n)) }
    "#{dir}:#{ENV["PATH"]}"
  end

  Result = Struct.new(:status, :stdout, :log, :calls, :argv, :headers, :summary)

  # `sizes:` is the catalog (an Array of rows, or an Array of pages of rows); `responses:`
  # overrides or adds raw [status, body] answers by path.
  def select_size(sizes: CATALOG, state: NEVER_APPLIED, responses: {}, tf_fail: false,
                  fallbacks: FALLBACKS, recreate: "false", tfvars: File.read(TFVARS))
    Dir.mktmpdir do |dir|
      pages = sizes.first.is_a?(Array) ? sizes : [ sizes ]
      answers = pages.each_with_index.to_h do |rows, i|
        links = i + 1 < pages.length ? { "pages" => { "next" => "https://api.example/next" } } : {}
        [ "/v2/sizes?per_page=200&page=#{i + 1}", [ 200, JSON.dump("sizes" => rows, "links" => links) ] ]
      end
      answers.merge(responses).each do |path, (code, body)|
        File.write(File.join(dir, path.tr("/?&=", "____")), "#{code}\n#{body}")
      end
      File.write(File.join(dir, "staging.tfvars"), tfvars)
      File.write(File.join(dir, "state.json"), state)

      env = {
        "PATH" => stub_bin(dir), "RESPONSES" => dir, "TF_STATE_FILE" => File.join(dir, "state.json"),
        "TF_FAIL" => tf_fail ? "1" : "0", "DO_TOKEN" => TOKEN, "DO_API_URL" => "https://api.example",
        "SIZE_FALLBACKS" => fallbacks, "MIN_MEMORY_MB" => "4096", "RECREATE" => recreate,
        "GITHUB_STEP_SUMMARY" => File.join(dir, "summary")
      }
      stdout, stderr, status = Open3.capture3(env, "bash", SCRIPT.to_s, chdir: dir)
      read = ->(name) { File.exist?(File.join(dir, name)) ? File.read(File.join(dir, name)) : "" }
      Result.new(status.exitstatus, stdout, stderr, read["calls"].lines(chomp: true),
        read["argv"], read["headers"], read["summary"])
    end
  end

  def droplet_answer(size) = { DROPLET_PATH => [ 200, JSON.dump("droplet" => { "size_slug" => size }) ] }

  def assert_selected(size, result)
    assert_equal 0, result.status, result.log
    # Byte-exact: the workflow captures stdout and hands it to terraform.
    assert_equal "#{size}\n", result.stdout
  end

  def assert_refused(result, message)
    assert_equal 1, result.status, result.log
    assert_empty result.stdout, "a refusal must not print a size"
    assert_match(/^::error::/, result.log)
    assert_match message, result.log
  end

  # --- Creating a droplet ------------------------------------------------------------

  test "the preferred size is used when the region sells it" do
    result = select_size(sizes: catalog(sold: [ "s-2vcpu-4gb" ]))

    assert_selected "s-2vcpu-4gb", result
    assert_no_match(/::warning::/, result.log)
    assert_empty result.summary
  end

  test "the 2026-11-23 refusal falls back to the first fallback the region sells, and says so" do
    result = select_size

    assert_selected "s-2vcpu-4gb-amd", result
    assert_match(/::warning::.*s-2vcpu-4gb-amd/, result.log)
    assert_match(/s-2vcpu-4gb: not sold in nyc3/, result.log)
    assert_match(/s-2vcpu-4gb-amd/, result.summary)
  end

  test "fallbacks are tried in order" do
    assert_selected "s-2vcpu-4gb-intel", select_size(sizes: catalog(unsold: [ "s-2vcpu-4gb-amd" ]))
    assert_selected "s-2vcpu-4gb-120gb-intel",
      select_size(sizes: catalog(unsold: %w[s-2vcpu-4gb-amd s-2vcpu-4gb-intel]))
  end

  test "a size listed in the region but flagged unavailable is not chosen" do
    assert_selected "s-2vcpu-4gb-intel", select_size(sizes: catalog(unavailable: [ "s-2vcpu-4gb-amd" ]))
  end

  test "a preferred size retired from the catalog falls back too" do
    result = select_size(sizes: catalog(retired: [ "s-2vcpu-4gb" ]))

    assert_selected "s-2vcpu-4gb-amd", result
    assert_match(/s-2vcpu-4gb: not in DigitalOcean's catalog/, result.log)
  end

  test "no acceptable size fails the run and names every one it tried" do
    result = select_size(sizes: catalog(unsold: all_4gb))

    assert_refused result, /no acceptable staging droplet size in nyc3/
    all_4gb.each { |size| assert_match(/#{size}: not sold in nyc3/, result.log) }
    assert_match(/Nothing was created or destroyed/, result.log)
  end

  test "a fallback smaller than the memory floor is never chosen" do
    assert_refused select_size(fallbacks: "s-2vcpu-2gb-amd"), /2048 MB is below the 4096 MB/
  end

  test "a fallback smaller than a larger preferred size is never chosen" do
    tfvars = %(region = "nyc3"\ndroplet_size = "s-4vcpu-8gb"\n)

    assert_refused select_size(tfvars: tfvars), /s-2vcpu-4gb-amd: 4096 MB is below the 8192 MB/
  end

  test "a size on the catalog's second page is found" do
    preferred, rest = catalog(sold: [ "s-2vcpu-4gb" ]).partition { |s| s["slug"] == "s-2vcpu-4gb" }
    result = select_size(sizes: [ rest, preferred ])

    assert_selected "s-2vcpu-4gb", result
    assert_includes result.calls, "/v2/sizes?per_page=200&page=2"
  end

  test "a catalog far larger than one command-line argument is still read" do
    filler = Array.new(1500) { |i| { "slug" => "filler-#{i}", "memory" => 1024, "available" => true, "regions" => AMD_REGIONS } }
    result = select_size(sizes: [ filler, filler, CATALOG ])

    assert_operator JSON.dump(filler).bytesize, :>, 128 * 1024
    assert_selected "s-2vcpu-4gb-amd", result
    assert_no_match(/Could not read/, result.log)
  end

  test "a later page that fails makes the whole catalog unreadable" do
    result = select_size(sizes: [ CATALOG, CATALOG ], responses: { "/v2/sizes?per_page=200&page=2" => [ 500, "" ] })

    assert_selected "s-2vcpu-4gb", result
    assert_match(/Could not read DigitalOcean's size catalog \(HTTP 500\)/, result.log)
  end

  test "the region comes from the tfvars" do
    result = select_size(tfvars: %(region = "sfo2"\ndroplet_size = "s-2vcpu-4gb"\n))

    assert_selected "s-2vcpu-4gb", result
  end

  test "an unreadable catalog asks for the preferred size and warns, so a refusal still fails the apply" do
    [ [ 500, "" ], [ 403, "{}" ], [ 200, "{\"sizes\": [" ], [ 200, "{}" ],
      [ 200, JSON.dump("sizes" => []) ] ].each do |answer|
      result = select_size(responses: { "/v2/sizes?per_page=200&page=1" => answer })

      assert_selected "s-2vcpu-4gb", result
      assert_match(/::warning::Could not read DigitalOcean's size catalog/, result.log)
    end
  end

  # --- A droplet exists --------------------------------------------------------------

  test "an existing droplet on the preferred size keeps it when the region has stopped selling it" do
    result = select_size(state: state(droplet: "s-2vcpu-4gb"), responses: droplet_answer("s-2vcpu-4gb"))

    assert_selected "s-2vcpu-4gb", result
    assert_equal [ DROPLET_PATH ], result.calls, "the catalog has no say over a droplet that is being kept"
  end

  test "an existing droplet on a fallback is not resized back once the preferred size returns" do
    result = select_size(sizes: catalog(sold: [ "s-2vcpu-4gb" ]),
      state: state(droplet: "s-2vcpu-4gb-amd"), responses: droplet_answer("s-2vcpu-4gb-amd"))

    assert_selected "s-2vcpu-4gb-amd", result
  end

  test "an existing droplet keeps its LIVE size, not the size state remembers" do
    result = select_size(state: state(droplet: "s-2vcpu-4gb"), responses: droplet_answer("s-4vcpu-8gb"))

    assert_selected "s-4vcpu-8gb", result
  end

  test "an existing droplet whose size cannot be read fails rather than risking a resize" do
    existing = state(droplet: "s-2vcpu-4gb")

    assert_refused select_size(state: existing, responses: { DROPLET_PATH => [ 500, "" ] }), /HTTP 500/
    assert_refused select_size(state: existing), /HTTP 000/
    assert_refused select_size(state: existing, responses: { DROPLET_PATH => [ 200, "{}" ] }), /carries no size/
    assert_refused select_size(state: existing, responses: { DROPLET_PATH => [ 200, "<html>" ] }), /carries no size/
    assert_refused select_size(state: existing, responses: droplet_answer("a\nsize=b")), /carries no size/
  end

  test "a droplet deleted out of band is a creation, so the catalog decides" do
    result = select_size(state: state(droplet: "s-2vcpu-4gb"), responses: { DROPLET_PATH => [ 404, "{}" ] })

    assert_selected "s-2vcpu-4gb-amd", result
  end

  test "recreate_droplet and a tainted droplet are creations, so the catalog decides" do
    live = droplet_answer("s-2vcpu-4gb")

    assert_selected "s-2vcpu-4gb-amd", select_size(state: state(droplet: "s-2vcpu-4gb"), responses: live, recreate: "true")
    assert_selected "s-2vcpu-4gb-amd", select_size(state: state(droplet: "s-2vcpu-4gb", tainted: true), responses: live)
  end

  test "a replacement refuses rather than destroying a droplet it may not be able to recreate" do
    unreadable = { "/v2/sizes?per_page=200&page=1" => [ 500, "" ] }
    existing = state(droplet: "s-2vcpu-4gb")

    assert_refused select_size(state: existing, recreate: "true", responses: unreadable), /Refusing to replace/
    assert_refused select_size(state: existing, recreate: "true", sizes: catalog(unsold: all_4gb)), /no acceptable/
  end

  test "unreadable or unparseable state fails, rather than reading as no droplet" do
    assert_refused select_size(tf_fail: true), /Could not read the staging Terraform state/
    assert_refused select_size(state: "not json"), /Could not parse the staging Terraform state/
    assert_refused select_size(state: ""), /Could not parse the staging Terraform state/
  end

  test "a droplet other than the module's is ignored" do
    other = JSON.parse(state(droplet: "s-2vcpu-4gb"))
    other["values"]["root_module"]["resources"].last["address"] = "digitalocean_droplet.other"

    assert_selected "s-2vcpu-4gb-amd", select_size(state: JSON.dump(other))
  end

  test "tfvars without a usable size or region fail" do
    assert_refused select_size(tfvars: %(region = "nyc3"\n)), /must assign droplet_size exactly once/
    assert_refused select_size(tfvars: %(droplet_size = "s-2vcpu-4gb"\n)), /must assign region exactly once/
    assert_refused select_size(tfvars: %(region = "nyc3"\ndroplet_size = "a"\ndroplet_size = "b"\n)),
      /must assign droplet_size exactly once/
  end

  test "the token is sent as a header and never appears on a command line or in the log" do
    result = select_size(state: state(droplet: "s-2vcpu-4gb"), responses: { DROPLET_PATH => [ 404, "" ] })

    assert_equal [ "Authorization: Bearer #{TOKEN}" ], result.headers.lines(chomp: true).uniq
    assert_no_match(/#{TOKEN}/, result.argv)
    assert_no_match(/#{TOKEN}/, result.log)
  end

  # --- The wiring ---------------------------------------------------------------------

  def steps = YAML.safe_load(WORKFLOW.read, aliases: true).dig("jobs", "deploy", "steps")
  def index(name) = steps.index { |s| s["name"] == name } || flunk("no step named #{name}")

  test "the size is chosen before the tailnet reap and the apply, and no failure is tolerated" do
    choose = index("Choose the droplet size")

    assert_operator choose, :<, index("Reap stale tailnet node (only when recreating)")
    assert_operator choose, :<, index("Terraform apply (staging)")
    [ choose, index("Terraform apply (staging)") ].each do |i|
      refute steps[i].key?("continue-on-error")
      refute steps[i].key?("if")
      assert_match(/\Aset -euo pipefail$/, steps[i]["run"])
    end
  end

  test "the chosen size reaches terraform after the var-file, which would otherwise win" do
    apply = steps[index("Terraform apply (staging)")]

    assert_equal "${{ steps.size.outputs.size }}", apply.dig("env", "DROPLET_SIZE")
    assert_match(/terraform apply .*-var-file=staging\.tfvars\s+\\\s+-var "droplet_size=\$DROPLET_SIZE"/, apply["run"])
    assert_equal "size", steps[index("Choose the droplet size")]["id"]
  end

  test "the script runs from the workflow's own commit and reads terraform's raw output" do
    checked_out_ref = steps.index { |s| s.dig("with", "ref") == "${{ steps.ref.outputs.ref }}" }
    assert_match(/scripts\/select-staging-droplet-size\.sh/, steps[0...checked_out_ref].map { |s| s["run"] }.join)
    assert_match(/\$RUNNER_TEMP\/ci-scripts\/select-staging-droplet-size\.sh/,
      steps[index("Choose the droplet size")]["run"])
    setup = steps.find { |s| s["uses"].to_s.start_with?("hashicorp/setup-terraform") }
    assert_equal false, setup.dig("with", "terraform_wrapper")
  end

  test "the workflow's fallbacks are the ones tested here, and none is the preferred size" do
    env = steps[index("Choose the droplet size")]["env"]

    assert_equal FALLBACKS, env["SIZE_FALLBACKS"]
    assert_equal "4096", env["MIN_MEMORY_MB"]
    assert_not_includes FALLBACKS.split, TFVARS.read[/^droplet_size\s*=\s*"([^"]+)"/, 1]
  end
end
