# frozen_string_literal: true

# PiExtensions — the registry of Pi extensions Zimmer loads into every Pi
# session, and the resolver that turns them into `pi -e <path>` arguments.
#
# == Why Pi needs this at all ==
#
# Claude Code and Codex arrive with MCP, hooks and plugins built in, so Zimmer
# only has to write their config files. Pi does not: it ships a skills
# mechanism and nothing else. Everything Zimmer relies on beyond skills is
# supplied by third-party Pi extensions, and an extension only takes effect if
# Pi is told to load it.
#
# `pi install npm:<pkg>` is Pi's own install path, but it mutates host-global
# state (settings.json under PiHome) at an unpredictable time. Zimmer instead
# installs the packages into a fixed prefix at image-build time and passes each
# entrypoint explicitly with `-e`, which keeps the set of active extensions a
# property of this file rather than of whatever happens to be in a shared
# settings.json. `-e` paths are honored even under `--no-extensions`.
#
# == Why an entry can be absent ==
#
# `@tadasant/pi-hooks` and `@tadasant/pi-plugins` are the Zimmer-side answer to
# Pi having no hooks and no AIR-plugin support. Both are published (0.1.0) and
# both are in the image, so nothing here is pending today.
#
# The absence machinery stays because absence is still possible and still has to
# degrade rather than crash: `pi -e <missing path>` makes Pi refuse to start, so
# an image built before a registry entry was added — a worker still running the
# previous base image after a deploy that bumped this file — would fail every Pi
# session outright. #resolved_paths returns only entrypoints that exist on disk,
# so such a session runs with whatever is present instead, and #missing reports
# the gap through CliStatusService, which is the observable answer to "is Pi
# fully wired" that an operator can reach without a shell on the box.
module PiExtensions
  # Where the Pi extension packages are installed. Overridable via ENV so CI
  # runners (which cannot write to /opt) can redirect to a writable path.
  INSTALL_DIR = ENV.fetch("PI_EXTENSIONS_DIR", "/opt/pi-extensions")

  # One entry per extension Zimmer wants active in a Pi session.
  #
  # `entrypoint` is relative to INSTALL_DIR/node_modules and is the file handed
  # to `pi -e`. `pending_publish` marks a package that is not on npm yet, so the
  # image cannot install it and its absence is expected rather than broken —
  # `npm install` is all-or-nothing, and one 404 would fail the whole base image.
  # Nothing carries the flag today; it exists so that adding an entry for a
  # package still in flight is a one-line change rather than a redesign.
  #
  # == Where an entrypoint comes from ==
  #
  # Read it out of the package's own `pi.extensions` manifest field
  # (`npm view <pkg> pi.extensions`) rather than guessing it. Pi loads
  # TypeScript extension sources directly, so a Pi package's entrypoint is a
  # `.ts` file inside the published tarball, not a compiled `dist/index.js`.
  # None of the three packages below ships a usable `dist/index.js`:
  # `pi-mcp-adapter` has a `dist/` holding only its public-export subset, and
  # the two `@tadasant` packages ship no `dist/` at all.
  #
  # `@tadasant/pi-plugins` declares TWO entrypoints in its own manifest — its own
  # `extensions/plugins.ts` and the `extensions/hooks.ts` of the `@tadasant/pi-hooks`
  # copy it bundles. Zimmer names only the first, and loads pi-hooks from the
  # top-level install instead. Either path works: pi-hooks marks itself loaded on
  # a `Symbol.for` global precisely so a user who has it both standalone and
  # bundled does not get two runners spawning every hook twice.
  #
  # A wrong entrypoint fails quietly, which is why it is worth checking against
  # the manifest. `pi -e <missing path>` makes Pi refuse to start, so
  # #resolved_paths filters to what is on disk — and a path that can never
  # exist becomes a Pi session running with the extension silently absent
  # rather than an error anyone sees. The base image's `test -f` smoke check
  # and the Dockerfile parity test below are the guard against that.
  Extension = Struct.new(:package, :version, :entrypoint, :purpose, :pending_publish, keyword_init: true) do
    def pending_publish? = !!pending_publish

    def path = File.join(INSTALL_DIR, "node_modules", entrypoint)

    def to_s = "#{package}@#{version}"
  end

  REGISTRY = [
    Extension.new(
      package: "pi-mcp-adapter",
      version: "2.32.1",
      entrypoint: File.join("pi-mcp-adapter", "index.ts"),
      purpose: "MCP servers (Pi has no native MCP support). Reads the .mcp.json " \
               "PiMcpConfigPostProcessor writes into the clone.",
      pending_publish: false
    ),
    Extension.new(
      package: "@tadasant/pi-hooks",
      version: "0.1.0",
      entrypoint: File.join("@tadasant", "pi-hooks", "extensions", "hooks.ts"),
      purpose: "Lifecycle hooks (Pi exposes lifecycle only through its TypeScript " \
               "extension API and has no hooks concept of its own).",
      pending_publish: false
    ),
    Extension.new(
      package: "@tadasant/pi-plugins",
      version: "0.1.0",
      entrypoint: File.join("@tadasant", "pi-plugins", "extensions", "plugins.ts"),
      purpose: "AIR Plugins — resolving a plugin manifest and activating the " \
               "skills, hooks and MCP servers it bundles. Requires pi-hooks and " \
               "pi-mcp-adapter to be loaded alongside it.",
      pending_publish: false
    )
  ].freeze

  module_function

  # @return [Array<Extension>] every declared extension
  def all
    REGISTRY
  end

  # The extensions the base image installs today — everything already published.
  # All three, as of `@tadasant/pi-hooks@0.1.0` and `@tadasant/pi-plugins@0.1.0`
  # reaching npm.
  #
  # Read by the Dockerfile parity test so the image's `npm install` list and this
  # registry cannot drift apart silently.
  #
  # @return [Array<Extension>]
  def installable
    all.reject(&:pending_publish?)
  end

  # Entrypoints that exist on disk right now, in registry order.
  #
  # Order matters: `@tadasant/pi-plugins` activates artifacts that the other two
  # implement, so it must load after them. Registry order encodes that, and this
  # method preserves it.
  #
  # @param file_system [FileSystemAdapter] injectable for tests
  # @return [Array<String>] absolute entrypoint paths
  def resolved_paths(file_system: nil)
    fs = file_system || RealFileSystemAdapter.new
    all.map(&:path).select { |path| fs.exists?(path) }
  end

  # Declared extensions whose entrypoint is not on disk.
  #
  # A `pending_publish` entry is expected to be missing until it ships; an entry
  # WITHOUT that flag being missing means the image build did not do what this
  # registry says it does, which is a real defect worth surfacing.
  #
  # @param file_system [FileSystemAdapter] injectable for tests
  # @return [Array<Extension>]
  def missing(file_system: nil)
    fs = file_system || RealFileSystemAdapter.new
    all.reject { |ext| fs.exists?(ext.path) }
  end

  # A one-line, operator-facing summary of what is loaded and what is not.
  # Surfaced through CliStatusService so the answer is reachable without a shell.
  #
  # @param file_system [FileSystemAdapter] injectable for tests
  # @return [String]
  def status_summary(file_system: nil)
    absent = missing(file_system: file_system)
    declared = all.size
    return "all #{declared} Pi extensions loaded" if absent.empty?

    pending, broken = absent.partition(&:pending_publish?)
    parts = []
    parts << "#{declared - absent.size}/#{declared} loaded"
    parts << "awaiting npm publish: #{pending.map(&:to_s).join(', ')}" if pending.any?
    parts << "MISSING FROM IMAGE: #{broken.map(&:to_s).join(', ')}" if broken.any?
    parts.join("; ")
  end
end
