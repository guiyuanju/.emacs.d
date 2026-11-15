// Sanitized markdown, code blocks with copy and expansion, long content folding, diffs.
import { marked, DOMPurify } from "js/vendor.js";
import { el, copyText } from "js/ui.js";
import { longContent, fileRef } from "js/model.js";

// file: links would be dropped as unsafe, so they become plain paths here and file links below.
DOMPurify.addHook("uponSanitizeAttribute", (node, data) => {
  if (node.tagName === "A" && data.attrName === "href" && /^file:/i.test(data.attrValue)) data.attrValue = fileRef(data.attrValue) || "";
});

DOMPurify.addHook("afterSanitizeAttributes", (node) => {
  if (node.tagName !== "A") return;
  node.classList.add("external");
  const ref = fileRef(node.getAttribute("href"));
  if (ref) {
    node.dataset.file = ref;
    node.classList.add("file-link");
    return;
  }
  node.setAttribute("target", "_blank");
  node.setAttribute("rel", "noopener noreferrer");
});

export function markdownHtml(text) {
  return DOMPurify.sanitize(marked.parse(text || "", { gfm: true }), { FORBID_TAGS: ["style", "form", "img"], FORBID_ATTR: ["style"] });
}

function copyButton(button, text) {
  button.onclick = async () => {
    try { await copyText(text()); button.textContent = "Copied"; }
    catch (_) { button.textContent = "Select text to copy"; }
  };
  return button;
}

// Wraps each pre of node with a copy action, and folds long ones; view.codeOpen keeps expanded blocks by index.
export function enhanceCodeBlocks(node, view) {
  view.codeOpen ??= new Set();
  let index = 0;
  for (const pre of node.querySelectorAll("pre")) {
    const position = index++;
    if (pre.parentElement?.classList.contains("code-container")) continue;
    const box = el("div", "code-container");
    const copy = copyButton(el("button", "code-copy", "Copy code"), () => pre.textContent);
    pre.replaceWith(box);
    box.append(copy, pre);
    if (longContent(pre.textContent)) {
      const expanded = view.codeOpen.has(position);
      const expand = el("button", "code-expand", expanded ? "Show less code" : "Show full code");
      pre.classList.toggle("code-preview", !expanded);
      expand.setAttribute("aria-expanded", String(expanded));
      expand.onclick = () => {
        const open = expand.getAttribute("aria-expanded") !== "true";
        expand.setAttribute("aria-expanded", String(open));
        pre.classList.toggle("code-preview", !open);
        if (open) view.codeOpen.add(position); else view.codeOpen.delete(position);
        expand.textContent = open ? "Show less code" : "Show full code";
      };
      box.append(expand);
    }
  }
}

// Bounds a long node to a preview with expand and copy actions; view.expanded survives re-renders.
export function foldContent(node, text, view) {
  if (!longContent(text)) return;
  const body = el("div", view.expanded ? "" : "content-preview");
  body.append(...Array.from(node.childNodes));
  const actions = el("div", "content-actions");
  const expand = el("button", "", view.expanded ? "Show less" : "Show full message");
  expand.setAttribute("aria-expanded", String(!!view.expanded));
  expand.onclick = () => {
    view.expanded = !view.expanded;
    body.classList.toggle("content-preview", !view.expanded);
    expand.setAttribute("aria-expanded", String(view.expanded));
    expand.textContent = view.expanded ? "Show less" : "Show full message";
  };
  actions.append(expand, copyButton(el("button", "", "Copy full text"), () => text));
  node.replaceChildren(body, actions);
}

export function diffPre(text) {
  const pre = el("pre", "diff");
  for (const line of text.split("\n")) {
    const kind = line.startsWith("@@") ? "hunk"
      : line.startsWith("+") && !line.startsWith("+++") ? "add"
      : line.startsWith("-") && !line.startsWith("---") ? "del" : "";
    pre.append(el("span", kind, line + "\n"));
  }
  return pre;
}
