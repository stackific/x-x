import { api } from "../shared/api";
import { $, tpl } from "../shared/dom";
import { relativeTime } from "../shared/relative-time";
import { applyStatusClass } from "../shared/status";

// Mirrors the Go-side scopeListItem in server.go: one row per plan in
// the project's .stax/ tree. systems carries the kebab-case ids the
// frontmatter declares — each is rendered as a chip-link into
// /system?id=<id> so a reader can jump straight to the system view.
type Scope = {
  slug: string;
  title: string;
  status: string;
  created: string;
  systems: string[];
};

type ScopesResponse = { scopes: Scope[] };

function renderError(host: HTMLElement, msg: string): void {
  const node = tpl("tpl-error");
  $('[data-slot="error"]', node).textContent = msg;
  host.replaceChildren(node);
}

function renderEmpty(host: HTMLElement): void {
  host.replaceChildren(tpl("tpl-empty"));
}

// renderSystems builds the per-scope chip row of system links. Each
// chip carries data-stop so the row-level <a class="row …"> outer link
// (which targets /scope?id=<slug>) is bypassed when the user clicks a
// system chip — clicking the chip should go to /system?id=<id>, not
// open the parent scope.
function renderSystems(parent: HTMLElement, systems: string[]): void {
  for (const id of systems) {
    const link = tpl("tpl-system-link");
    const a = link.querySelector<HTMLAnchorElement>("a");
    if (!a) continue;
    a.href = `/system?id=${encodeURIComponent(id)}`;
    a.textContent = id;
    a.addEventListener("click", (e) => e.stopPropagation());
    parent.appendChild(link);
  }
}

function renderList(host: HTMLElement, scopes: Scope[]): void {
  if (scopes.length === 0) {
    renderEmpty(host);
    return;
  }
  const frag = document.createDocumentFragment();
  for (const s of scopes) {
    const node = tpl("tpl-scope");
    const card = node.querySelector<HTMLAnchorElement>("a");
    if (card) card.href = `/scope?id=${encodeURIComponent(s.slug)}`;
    $('[data-slot="title"]', node).textContent = s.title || s.slug;
    const statusEl = $<HTMLSpanElement>('[data-slot="status"]', node);
    if (s.status) {
      statusEl.textContent = s.status;
      applyStatusClass(statusEl, s.status);
    } else {
      statusEl.hidden = true;
    }
    $('[data-slot="created"]', node).textContent = relativeTime(s.created);
    const systemsHost = $<HTMLDivElement>('[data-slot="systems"]', node);
    renderSystems(systemsHost, s.systems);
    frag.appendChild(node);
  }
  host.replaceChildren(frag);
}

export async function scopes(): Promise<void> {
  const host = $<HTMLDivElement>("#scopes-list");
  try {
    const data = await api<ScopesResponse>("/api/scopes");
    renderList(host, data.scopes ?? []);
  } catch (err) {
    renderError(host, `Failed to load scopes: ${(err as Error).message}`);
  }
}
