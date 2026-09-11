# frozen_string_literal: true

# Renders `infra/terraform/cloud-init.yaml.tftpl` the way Terraform's `templatefile()` would,
# so a test can assert against the cloud-config the DROPLET receives rather than against the
# template's source text.
#
# WHY THIS EXISTS RATHER THAN SHELLING OUT TO TERRAFORM: the template is rendered exactly once
# per droplet, at first boot, and `ignore_changes = [user_data]` means a broken render surfaces
# nowhere until someone rebuilds the box -- at which point cloud-init refuses the whole file
# and the droplet comes up with no Docker and no Tailscale, i.e. unreachable over a tailnet it
# never joined. CI has no Terraform binary and no DigitalOcean credentials, so the choice is
# between this and no check at all.
#
# It is NOT a Terraform implementation. It handles exactly the constructs this one file uses --
# `${ ... }` interpolation, and `%{ if ... ~}` / `%{ endif ~}` directives that start at column 0
# and right-trim -- and RAISES on every other shape it can see, so a template that grows a
# construct this cannot model fails loudly here instead of being silently half-rendered.
#
# The raises are not decoration. Terraform's whitespace rules are the part that is easy to model
# WRONG rather than not at all: an INDENTED `%{ if ~}` emits its own leading spaces (they belong
# to the preceding literal, and only `%{~` trims them), and a directive without the `~` leaves
# its newline behind. Dropping the whole line is faithful to `%{ ... ~}` at column 0 and to
# nothing else, so anything else has to stop this renderer rather than be approximated.
module CloudInitRender
  TEMPLATE = Rails.root.join("infra/terraform/cloud-init.yaml.tftpl")

  # Interpolations are replaced with an inert scalar rather than a realistic value: the point
  # is the SHAPE of the document (is it parseable, is the gated block in or out), and a real
  # SSH key or auth key in a test fixture buys nothing.
  PLACEHOLDER = "RENDERED-VALUE"

  # A line that is nothing but a directive, at column 0, right-trimming. Every `%{` in this
  # template is one of these, and `truthy?`/`apply_directive` reject anything that is not.
  DIRECTIVE = /\A%\{\s*(?<body>.*?)\s*(?<trim>~?)\}\s*\z/

  # Terraform's two literal escapes. Neither appears in this template, and the interpolation
  # substitution below would mangle both rather than pass them through.
  ESCAPES = /\$\$\{|%%\{/

  class UnsupportedTemplate < StandardError; end

  class << self
    # The variables main.tf passes, with the defaults a rendering assumes unless a test says
    # otherwise. Booleans here are "is this block in or out", not Terraform values -- except
    # node_exporter_enabled, which mirrors main.tf's own `false` so that a no-argument render is
    # a config some real droplet actually gets.
    def defaults
      { "ssh_host_ed25519_key" => "key", "domain" => "example.com", "node_exporter_enabled" => false }
    end

    def render(vars = {})
      vars = defaults.merge(vars.transform_keys(&:to_s))
      emit = [ true ]
      out = []

      File.read(TEMPLATE).each_line do |line|
        raise UnsupportedTemplate, "literal escape this renderer cannot model: #{line}" if line.match?(ESCAPES)

        if (m = line.match(DIRECTIVE))
          raise UnsupportedTemplate, "directive without `~}`, whose newline this renderer would eat: #{line}" if m[:trim].empty?

          apply_directive(m[:body], emit, vars)
          next
        end

        raise UnsupportedTemplate, "inline or indented template directive this renderer cannot model: #{line}" if line.match?(/%\{/)

        out << line.gsub(/\$\{[^}\n]*\}/, PLACEHOLDER) if emit.all?
      end

      raise UnsupportedTemplate, "unclosed %{ if } in #{TEMPLATE}" unless emit.size == 1

      out.join
    end

    # The rendered cloud-config as cloud-init would parse it. `safe_load` is the same
    # strictness cloud-init applies -- a document it rejects is a document that runs NOTHING.
    def parse(vars = {})
      YAML.safe_load(render(vars))
    end

    private

    def apply_directive(body, emit, vars)
      case body
      when "endif"
        raise UnsupportedTemplate, "%{ endif } with no matching %{ if }" if emit.size == 1

        emit.pop
      when /\Aif\s+(?<cond>.+)\z/
        emit.push(truthy?(Regexp.last_match[:cond], vars))
      else
        raise UnsupportedTemplate, "directive this renderer cannot model: %{ #{body} }"
      end
    end

    # The two condition shapes the template uses: `name != ""` and a bare boolean `name`.
    def truthy?(cond, vars)
      case cond
      when /\A(?<name>\w+)\s*!=\s*""\z/ then fetch(vars, Regexp.last_match[:name]).to_s != ""
      when /\A\w+\z/ then !!fetch(vars, cond)
      else raise UnsupportedTemplate, "condition this renderer cannot model: #{cond}"
      end
    end

    def fetch(vars, name)
      raise UnsupportedTemplate, "template reads an unknown variable: #{name}" unless vars.key?(name)

      vars.fetch(name)
    end
  end
end
