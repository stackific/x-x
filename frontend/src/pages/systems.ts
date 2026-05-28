import { api } from "../shared/api";
import { $, tpl } from "../shared/dom";

// `chaptersFound` / `total` are placeholders mirroring the minibooks layout —
// the count slot will get a real field name once /api/systems exposes one.
type System = {
  id?: string;
  name: string;
  brief?: string;
  chaptersFound?: number;
  total?: number;
};

type SystemsResponse = { systems: System[] };

function formatCount(s: System): string {
  if (s.chaptersFound !== undefined && s.total !== undefined) {
    return `${s.chaptersFound} / ${s.total} chapters`;
  }
  // Placeholder mirroring the minibooks page until /api/systems exposes a
  // real count. Derived deterministically from id so the same system shows
  // the same numbers across reloads.
  const seed = s.id ?? s.name;
  let h = 0;
  for (let i = 0; i < seed.length; i++) {
    h = ((h << 5) - h + seed.charCodeAt(i)) | 0;
  }
  const total = 5 + (Math.abs(h) % 8);
  const found = Math.abs(h >> 3) % (total + 1);
  return `${found} / ${total} chapters`;
}

export async function systems(): Promise<void> {
  const host = $<HTMLDivElement>("#systems-list");
  try {
    const { systems: items } = await api<SystemsResponse>("/api/systems");
    if (!items.length) {
      host.replaceChildren(tpl("tpl-empty"));
      return;
    }
    const frag = document.createDocumentFragment();
    for (const s of items) {
      const node = tpl("tpl-system");
      const a = node.querySelector<HTMLAnchorElement>("a");
      if (a && s.id) a.href = `/systems?id=${encodeURIComponent(s.id)}`;
      $('[data-slot="name"]', node).textContent = s.name;
      $('[data-slot="brief"]', node).textContent = s.brief ?? "";
      $('[data-slot="count"]', node).textContent = formatCount(s);
      frag.appendChild(node);
    }
    host.replaceChildren(frag);
  } catch (err) {
    const node = tpl("tpl-error");
    const msg = err instanceof Error ? err.message : String(err);
    $('[data-slot="error"]', node).textContent = `Request failed: ${msg}`;
    host.replaceChildren(node);
  }
}
