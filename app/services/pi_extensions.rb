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
# Pi having no hooks and no AIR-plugin support. They live in the public
# `tadasant/pi-extensions` repo and are NOT yet published to npm — both 404 on
# the registry, and the release PR is open but unmerged. An unpublished package
# cannot be in the image, so the image build must not name it: `npm install` is
# all-or-nothing and a single 404 would fail the whole base image.
#
# So the registry declares all three with their pinned versions, and
# `pending_publish` marks the ones the image does not install yet.
# #resolved_paths returns only entrypoints that actually exist on disk, so a Pi
# session runs with whatever is present rather than dying on an `-e` path that
# is not there. #missing reports the gap through CliStatusService, which is the
# observable answer to "is Pi fully wired yet" that an operator can reach
# without a shell on the box.
#
# When `v0.1.0` publishes, the change is one Dockerfile line plus dropping
# `pending_publish:` here — no code change.
module PiExtensions
  # Where the Pi extension packages are installed. Overridable via ENV so CI
  # runners (which cannot write to /opt) can redirect to a writable path.
  INSTALL_DIR = ENV.fetch("PI_EXTENSIONS_DIR", "/opt/pi-extensions")

  # One entry per extension Zimmer wants active in a Pi session.
  #
  # `entrypoint` is relative to INSTALL_DIR/node_modules and is the file handed
  # to `pi -e`. `pending_publish` means the package is not on npm yet, so the
  # image does not install it and its absence is expected rather than broken.
  Extension = Struct.new(:package, :version, :entrypoint, :purpose, :pending_publish, keyword_init: true) do
    def pending_publish? = !!pending_publish

    def path = File.join(INSTALL_DIR, "node_modules", entrypoint)

    def to_s = "#{package}@#{version}"
  end

  REGISTRY = [
    Extension.new(
      package: "pi-mcp-adapter",
      version: "2.32.1",
      entrypoint: File.join("pi-mcp-adapter", "dist", "index.js"),
      purpose: "MCP servers (Pi has no native MCP support). Reads the .mcp.json " \
               "PiMcpConfigPostProcessor writes into the clone.",
      pending_publish: false
    ),
    Extension.new(
      package: "@tadasant/pi-hooks",
      version: "0.1.0",
      entrypoint: File.join("@tadasant", "pi-hooks", "dist", "index.js"),
      purpose: "Lifecycle hooks (Pi exposes lifecycle only through its TypeScript " \
               "extension API and has no hooks concept of its own).",
      pending_publish: true
    ),
    Extension.new(
      package: "@tadasant/pi-plugins",
      version: "0.1.0",
      entrypoint: File.join("@tadasant", "pi-plugins", "dist", "index.js"),
      purpose: "AIR Plugins — resolving a plugin manifest and activating the " \
               "skills, hooks and MCP servers it bundles. Requires pi-hooks and " \
               "pi-mcp-adapter to be loaded alongside it.",
      pending_publish: true
    )
  ].freeze

  module_function

  # @return [Array<Extension>] every declared extension
  def all
    REGISTRY
  end

  # The extensions the base image installs today — everything already published.
  #
  # Read by the Dockerfile parity test so the image's `npm install` list and this
  # registry cannot drift apart silently.
  #
  # @return [Array<Extension>]
  def installable
    REGISTRY.reject(&:pending_publish?)
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
    REGISTRY.map(&:path).select { |path| fs.exists?(path) }
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
    REGISTRY.reject { |ext| fs.exists?(ext.path) }
  end

  # A one-line, operator-facing summary of what is loaded and what is not.
  # Surfaced through CliStatusService so the answer is reachable without a shell.
  #
  # @param file_system [FileSystemAdapter] injectable for tests
  # @return [String]
  def status_summary(file_system: nil)
    absent = missing(file_system: file_system)
    return "all #{REGISTRY.size} Pi extensions loaded" if absent.empty?

    pending, broken = absent.partition(&:pending_publish?)
    parts = []
    parts << "#{REGISTRY.size - absent.size}/#{REGISTRY.size} loaded"
    parts << "awaiting npm publish: #{pending.map(&:to_s).join(', ')}" if pending.any?
    parts << "MISSING FROM IMAGE: #{broken.map(&:to_s).join(', ')}" if broken.any?
    parts.join("; ")
  end
end
