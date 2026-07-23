// @ts-check
import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";
import { remarkMermaid } from "./src/plugins/remark-mermaid.mjs";

// The canonical public URL. Override with SITE_URL at build time (Cloudflare
// Pages preview deployments get a per-branch hostname).
const site = process.env.SITE_URL || "https://docs.zimmer.tadasant.com";

export default defineConfig({
  site,
  markdown: {
    // Runs before Expressive Code, so ```mermaid fences are swapped for a raw
    // HTML node and never reach the syntax highlighter.
    remarkPlugins: [remarkMermaid],
  },
  integrations: [
    starlight({
      title: "Zimmer",
      description:
        "Self-hostable orchestration for AI coding agents. Sessions as isolated clones, a lifecycle you can reason about, and a catalog that wires the agent's context.",
      tagline: "Self-hostable orchestration for AI coding agents",
      logo: {
        light: "./src/assets/logo-light.svg",
        dark: "./src/assets/logo-dark.svg",
        replacesTitle: false,
      },
      favicon: "/favicon.svg",
      social: [
        {
          icon: "github",
          label: "GitHub",
          href: "https://github.com/tadasant/zimmer",
        },
      ],
      editLink: {
        baseUrl: "https://github.com/tadasant/zimmer/edit/main/docs/",
      },
      lastUpdated: true,
      customCss: [
        // Self-hosted variable fonts (bundled + hashed by Astro — no external
        // requests, works offline, CI-safe). Order matters: fonts before theme.
        "@fontsource-variable/ibm-plex-sans/wght.css",
        "@fontsource-variable/ibm-plex-sans/wght-italic.css",
        "@fontsource-variable/jetbrains-mono/wght.css",
        "./src/styles/custom.css",
      ],
      components: {
        // Injects the client-side Mermaid renderer on every page.
        Head: "./src/components/Head.astro",
        // Adds a page-level "Copy as Markdown" control beside every page title.
        PageTitle: "./src/components/PageTitle.astro",
      },
      sidebar: [
        {
          label: "Introduction",
          items: [
            { label: "What Zimmer is", slug: "intro/what-zimmer-is" },
            { label: "Philosophy", slug: "intro/philosophy" },
            { label: "Architecture", slug: "intro/architecture" },
            { label: "Core concepts", slug: "intro/concepts" },
          ],
        },
        {
          label: "Getting started",
          items: [
            { label: "Run it locally", slug: "start/local" },
            { label: "Run it in containers", slug: "start/containers" },
            { label: "Your first session", slug: "start/first-session" },
            { label: "Configuration reference", slug: "start/configuration" },
          ],
        },
        {
          label: "Sessions",
          items: [
            { label: "The session lifecycle", slug: "sessions/lifecycle" },
            { label: "Spawning and monitoring", slug: "sessions/spawning" },
            { label: "Goals and stop conditions", slug: "sessions/goals" },
            { label: "Transcripts", slug: "sessions/transcripts" },
            { label: "Triggers and schedules", slug: "sessions/triggers" },
            { label: "Elicitation", slug: "sessions/elicitation" },
          ],
        },
        {
          label: "Agent context (AIR)",
          items: [
            { label: "AIR: the mental model", slug: "air/overview" },
            { label: "How Zimmer consumes AIR", slug: "air/zimmer-integration" },
            { label: "Agent roots", slug: "air/agent-roots" },
            { label: "Skills, plugins, hooks, references", slug: "air/artifacts" },
            { label: "MCP servers", slug: "air/mcp-servers" },
          ],
        },
        {
          label: "Auth",
          items: [
            { label: "Auth architecture", slug: "auth/overview" },
            { label: "Agent harness credentials", slug: "auth/harness" },
            { label: "MCP server OAuth", slug: "auth/mcp-oauth" },
          ],
        },
        {
          label: "Extending Zimmer",
          items: [
            { label: "The REST API", slug: "extend/rest-api" },
            { label: "Zimmer's MCP server", slug: "extend/mcp-server" },
            { label: "Adding an agent harness", slug: "extend/agent-harness" },
            { label: "Extensions", slug: "extend/extensions" },
            { label: "Transcript hooks", slug: "extend/transcript-hooks" },
            { label: "MCP Apps in the session UI (spike)", slug: "extend/mcp-apps-spike" },
          ],
        },
        {
          label: "Operating Zimmer",
          items: [
            { label: "Self-hosting Zimmer", slug: "operate/self-hosting" },
            { label: "Deploying", slug: "operate/deploying" },
            { label: "Provisioning and secrets", slug: "operate/provisioning" },
            { label: "SSH and tailnet access", slug: "operate/ssh-access" },
            { label: "The private companion repo", slug: "operate/companion-repo" },
            { label: "Background jobs", slug: "operate/background-jobs" },
            { label: "Observability", slug: "operate/observability" },
            { label: "Testing philosophy", slug: "operate/testing" },
          ],
        },
        {
          label: "Reality check",
          items: [
            { label: "Known limitations", slug: "limitations" },
            { label: "Contributing to these docs", slug: "meta/contributing" },
          ],
        },
      ],
    }),
  ],
});
