export function $<T extends Element>(selector: string, root: ParentNode = document): T {
  const el = root.querySelector<T>(selector);
  if (!el) throw new Error(`Element not found: ${selector}`);
  return el;
}

export function tpl(id: string): DocumentFragment {
  const t = document.getElementById(id);
  if (!(t instanceof HTMLTemplateElement)) {
    throw new Error(`Template not found: #${id}`);
  }
  return t.content.cloneNode(true) as DocumentFragment;
}
