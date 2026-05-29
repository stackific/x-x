import { api } from "../shared/api";
import { $, tpl } from "../shared/dom";
import { applyRelativeTime } from "../shared/relative-time";
import { applyStatusClass, paintFlagIcon } from "../shared/status";

// Mirrors the Go-side workItemListItem in server.go: one row per work
// item in the project's .stax/ tree. systems carries the kebab-case ids
// the frontmatter declares — each is rendered as a chip-link into
// /system?id=<id> so a reader can jump straight to the system view.
type WorkItem = {
  slug: string;
  title: string;
  status: string;
  created: string;
  systems: string[];
  hasOpenTasks: boolean;
};

type WorkItemsResponse = { workItems: WorkItem[] };

function renderError(host: HTMLElement, msg: string): void {
  const node = tpl("tpl-error");
  $('[data-slot="error"]', node).textContent = msg;
  host.replaceChildren(node);
}

function renderEmpty(host: HTMLElement): void {
  host.replaceChildren(tpl("tpl-empty"));
}

// renderSystems builds the per-work-item chip row of system links. Each
// chip carries data-stop so the row-level <a class="row …"> outer link
// (which targets /work-item?id=<slug>) is bypassed when the user clicks
// a system chip — clicking the chip should go to /system?id=<id>, not
// open the parent work item.
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

function renderList(host: HTMLElement, items: WorkItem[]): void {
  if (items.length === 0) {
    renderEmpty(host);
    return;
  }
  const frag = document.createDocumentFragment();
  for (const s of items) {
    const node = tpl("tpl-work-item");
    const card = node.querySelector<HTMLAnchorElement>("a");
    if (card) card.href = `/work-item?id=${encodeURIComponent(s.slug)}`;
    const icon = node.querySelector<HTMLElement>("i");
    if (icon) paintFlagIcon(icon, s.status, s.hasOpenTasks);
    $('[data-slot="title"]', node).textContent = s.title || s.slug;
    const statusEl = $<HTMLSpanElement>('[data-slot="status"]', node);
    if (s.status) {
      statusEl.textContent = s.status;
      applyStatusClass(statusEl, s.status);
    } else {
      statusEl.hidden = true;
    }
    applyRelativeTime($('[data-slot="created"]', node), s.created);
    const systemsHost = $<HTMLDivElement>('[data-slot="systems"]', node);
    renderSystems(systemsHost, s.systems);
    frag.appendChild(node);
  }
  host.replaceChildren(frag);
}

export async function workItems(): Promise<void> {
  const host = $<HTMLDivElement>("#work-items-list");
  try {
    const data = await api<WorkItemsResponse>("/api/work-items");
    renderList(host, data.workItems ?? []);
  } catch (err) {
    renderError(host, `Failed to load work items: ${(err as Error).message}`);
  }
}
