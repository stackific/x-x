import { api } from "../shared/api";
import { $, tpl } from "../shared/dom";
import { qs as getQs } from "../shared/qs";

// Mirror the Go-side searchResponse in server.go. Two grouped lists
// driven from the same handler that powers /work-items and /systems —
// the same row shapes apply, so we reuse the templates for visual
// continuity with the dedicated list pages.
type WorkItem = {
  slug: string;
  title: string;
  status: string;
  created: string;
  systems: string[];
  hasOpenTasks: boolean;
};

type System = {
  id: string;
  name: string;
  brief?: string;
  workItems: number;
};

type SearchResponse = {
  query: string;
  workItems: WorkItem[];
  systems: System[];
};

// formatDate / formatCount mirror /work-items and /systems so a row in
// search results looks identical to one on the dedicated list page.
function formatDate(iso: string): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleDateString(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
  });
}

function formatWorkItemCount(n: number): string {
  return `${n} ${n === 1 ? "work item" : "work items"}`;
}

// renderWorkItemRow stamps a single work-item card. Identical body to the
// /work-items page renderer — kept inline (rather than imported from
// work-items.ts) because work-items.ts is its own entry chunk and importing
// across pages would balloon the search bundle.
function renderWorkItemRow(s: WorkItem): DocumentFragment {
  const node = tpl("tpl-work-item");
  const card = node.querySelector<HTMLAnchorElement>("a");
  if (card) card.href = `/work-item?id=${encodeURIComponent(s.slug)}`;
  if (s.hasOpenTasks) {
    const icon = node.querySelector<HTMLElement>("i");
    if (icon) icon.classList.add("primary-text");
  }
  $('[data-slot="title"]', node).textContent = s.title || s.slug;
  $('[data-slot="created"]', node).textContent = formatDate(s.created);
  const statusEl = $<HTMLSpanElement>('[data-slot="status"]', node);
  if (s.status) {
    statusEl.textContent = s.status;
  } else {
    statusEl.hidden = true;
  }
  const systemsHost = $<HTMLDivElement>('[data-slot="systems"]', node);
  for (const id of s.systems ?? []) {
    const link = tpl("tpl-system-chip");
    const a = link.querySelector<HTMLAnchorElement>("a");
    if (!a) continue;
    a.href = `/system?id=${encodeURIComponent(id)}`;
    a.textContent = id;
    a.addEventListener("click", (e) => e.stopPropagation());
    systemsHost.appendChild(link);
  }
  return node;
}

function renderSystemRow(sys: System): DocumentFragment {
  const node = tpl("tpl-system");
  const a = node.querySelector<HTMLAnchorElement>("a");
  if (a && sys.id) a.href = `/system?id=${encodeURIComponent(sys.id)}`;
  $('[data-slot="name"]', node).textContent = sys.name;
  $('[data-slot="brief"]', node).textContent = sys.brief ?? "";
  $('[data-slot="count"]', node).textContent = formatWorkItemCount(sys.workItems ?? 0);
  return node;
}

function renderSection(host: HTMLElement, emptyEl: HTMLElement, items: DocumentFragment[]): void {
  host.replaceChildren();
  if (!items.length) {
    emptyEl.hidden = false;
    return;
  }
  emptyEl.hidden = true;
  const frag = document.createDocumentFragment();
  for (const node of items) {
    frag.appendChild(node);
  }
  host.replaceChildren(frag);
}

function showHint(hintEl: HTMLElement): void {
  hintEl.hidden = false;
}

function hideHint(hintEl: HTMLElement): void {
  hintEl.hidden = true;
}

function setSectionsVisible(visible: boolean): void {
  $<HTMLDivElement>("#search-work-items-section").hidden = !visible;
  $<HTMLDivElement>("#search-systems-section").hidden = !visible;
}

export function search(): void {
  const input = $<HTMLInputElement>("#search-input");
  const hint = $<HTMLParagraphElement>("#search-hint");
  const emptyAll = $<HTMLParagraphElement>("#search-empty-all");
  const workItemsHost = $<HTMLDivElement>("#search-work-items");
  const workItemsEmpty = $<HTMLParagraphElement>("#search-work-items-empty");
  const systemsHost = $<HTMLDivElement>("#search-systems");
  const systemsEmpty = $<HTMLParagraphElement>("#search-systems-empty");

  const initial = getQs("q");
  if (initial) input.value = initial;

  // Keeps the URL in sync with the typed query so a search result is
  // shareable / bookmarkable. replaceState (not pushState) so back-
  // button history isn't flooded with one entry per keystroke.
  function syncURL(q: string): void {
    const u = new URL(location.href);
    if (q) u.searchParams.set("q", q);
    else u.searchParams.delete("q");
    history.replaceState(null, "", u.toString());
  }

  let inflight = 0;
  async function run(q: string): Promise<void> {
    syncURL(q);
    if (!q) {
      showHint(hint);
      emptyAll.hidden = true;
      setSectionsVisible(false);
      workItemsHost.replaceChildren();
      systemsHost.replaceChildren();
      return;
    }
    hideHint(hint);
    const token = ++inflight;
    try {
      const data = await api<SearchResponse>(`/api/search?q=${encodeURIComponent(q)}`);
      // Drop stale responses — only the most recent keystroke wins.
      if (token !== inflight) return;
      const workItemRows = (data.workItems ?? []).map(renderWorkItemRow);
      const systemRows = (data.systems ?? []).map(renderSystemRow);
      setSectionsVisible(true);
      renderSection(workItemsHost, workItemsEmpty, workItemRows);
      renderSection(systemsHost, systemsEmpty, systemRows);
      emptyAll.hidden = workItemRows.length > 0 || systemRows.length > 0;
    } catch (err) {
      if (token !== inflight) return;
      const msg = err instanceof Error ? err.message : String(err);
      setSectionsVisible(false);
      workItemsHost.replaceChildren();
      systemsHost.replaceChildren();
      emptyAll.hidden = true;
      const node = tpl("tpl-error");
      $('[data-slot="error"]', node).textContent = `Search failed: ${msg}`;
      hint.replaceChildren(node);
      hint.hidden = false;
    }
  }

  let timer: number | undefined;
  input.addEventListener("input", () => {
    window.clearTimeout(timer);
    timer = window.setTimeout(() => run(input.value.trim()), 150);
  });

  if (initial) void run(initial.trim());
}
