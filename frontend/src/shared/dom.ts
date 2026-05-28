// The two DOM primitives every page uses. Centralized here so the
// "throw on missing" contract is uniform — call sites can chain
// `.textContent = ...` / `.appendChild(...)` without a null guard,
// trusting that an absent element is a developer error caught loudly
// (in the matching HTML template / partial) rather than silently
// dropped.

// $ — querySelector with throw-on-miss. The generic `T` lets callers
// pin the element type (`$<HTMLAnchorElement>("a")`) so the returned
// node's interface is available without an `as` cast at the use site.
//
// `selector` — any CSS selector accepted by `querySelector`.
// `root`     — search scope. Defaults to `document` so most calls read
//              naturally (`$("#system-name")`); pass a `DocumentFragment`
//              when filling slots inside a freshly-cloned template (see
//              `tpl` below) so the search doesn't reach into the parent
//              page and grab a colliding id.
export function $<T extends Element>(selector: string, root: ParentNode = document): T {
  const el = root.querySelector<T>(selector);
  if (!el) throw new Error(`Element not found: ${selector}`);
  return el;
}

// tpl — clone a `<template id="...">` element by id and return its
// content as a `DocumentFragment` ready to be filled in. The id MUST
// resolve to an `HTMLTemplateElement`; anything else (or a missing id)
// throws so a typo in HTML or TS surfaces immediately rather than
// silently rendering an empty row.
//
// The clone is deep (`cloneNode(true)`) — the returned fragment is a
// detached subtree the caller owns, so multiple clones of the same
// `<template>` produce independent nodes that can be filled and
// appended without aliasing.
//
// Usage pattern:
//   const node = tpl("tpl-scope");
//   $('[data-slot="title"]', node).textContent = s.title;
//   host.appendChild(node);
export function tpl(id: string): DocumentFragment {
  const t = document.getElementById(id);
  if (!(t instanceof HTMLTemplateElement)) {
    throw new Error(`Template not found: #${id}`);
  }
  return t.content.cloneNode(true) as DocumentFragment;
}
