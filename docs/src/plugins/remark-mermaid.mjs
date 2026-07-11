import { visit } from "unist-util-visit";

/**
 * Swap ```mermaid fences for a raw HTML placeholder that the client-side
 * renderer (src/components/Head.astro) picks up.
 *
 * This has to happen in remark rather than rehype: Expressive Code claims code
 * blocks during the rehype pass, so by then the fence is already a highlighted
 * <pre>. The diagram source is base64-encoded into a data attribute so it
 * survives HTML escaping untouched.
 */
export function remarkMermaid() {
  return (tree) => {
    visit(tree, "code", (node, index, parent) => {
      if (node.lang !== "mermaid" || !parent || index === undefined) return;

      const encoded = Buffer.from(node.value, "utf8").toString("base64");
      const caption = (node.meta || "").trim();

      parent.children[index] = {
        type: "html",
        value:
          `<figure class="mermaid-figure">` +
          `<div class="mermaid-diagram" data-mermaid="${encoded}" role="img" aria-label="${
            caption ? escapeHtml(caption) : "Diagram"
          }"></div>` +
          (caption ? `<figcaption>${escapeHtml(caption)}</figcaption>` : "") +
          `</figure>`,
      };
    });
  };
}

function escapeHtml(value) {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
