import { api } from "../shared/api";
import { $, tpl } from "../shared/dom";

// Mirrors the Go-side systemEntry in server.go. `scopes` is the live
// per-system work-item count surfaced by /api/systems so the list view can
// render "N scope(s)" without an extra round-trip.
type System = {
  id: string;
  name: string;
  scopes: number;
  brief?: string;
};

type SystemsResponse = { systems: System[] };

// formatCount returns the small-text label rendered on each system
// row. Singular vs plural keeps the wording natural across the "0",
// "1", and "N" cases.
function formatCount(n: number): string {
  return `${n} ${n === 1 ? "scope" : "scopes"}`;
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
      if (a && s.id) a.href = `/system?id=${encodeURIComponent(s.id)}`;
      $('[data-slot="name"]', node).textContent = s.name;
      $('[data-slot="brief"]', node).textContent = s.brief ?? "";
      $('[data-slot="count"]', node).textContent = formatCount(s.scopes ?? 0);
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
