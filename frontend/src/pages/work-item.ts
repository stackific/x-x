import { api } from "../shared/api";
import { $, tpl } from "../shared/dom";
import { qs as getQs } from "../shared/qs";
import { applyRelativeTime } from "../shared/relative-time";
import { applyStatusClass, paintFlagIcon } from "../shared/status";

// Mirrors the Go-side workItemDetail in server.go: a single work item's
// frontmatter fields plus the markdown body pre-rendered to HTML
// server-side (goldmark with HTML escaping enabled, so innerHTML is
// safe here). supersededBy carries the slug + title of every newer
// work item that replaced this one, so the UI can render human-readable
// chips instead of raw filename slugs.
type WorkItemRelation = { slug: string; title: string };

type WorkItemDetail = {
  slug: string;
  title: string;
  status: string;
  created: string;
  systems: string[];
  supersedes: WorkItemRelation[] | null;
  supersededBy: WorkItemRelation[] | null;
  hasOpenTasks: boolean;
  html: string;
};

function renderError(host: HTMLElement, msg: string): void {
  const node = tpl("tpl-error");
  $('[data-slot="error"]', node).textContent = msg;
  host.replaceChildren(node);
}

function renderRelationLinks(host: HTMLElement, rels: readonly WorkItemRelation[]): void {
  host.replaceChildren();
  for (const rel of rels) {
    const link = tpl("tpl-work-item-link");
    const a = link.querySelector<HTMLAnchorElement>("a");
    if (!a) continue;
    a.href = `/work-item?id=${encodeURIComponent(rel.slug)}`;
    a.textContent = rel.title || rel.slug;
    a.title = rel.slug;
    host.appendChild(link);
  }
}

function toggleRelationRow(rowID: string, listID: string, rels: WorkItemRelation[] | null): void {
  const row = $<HTMLDivElement>(`#${rowID}`);
  const list = $<HTMLDivElement>(`#${listID}`);
  if (!rels?.length) {
    row.hidden = true;
    list.replaceChildren();
    return;
  }
  row.hidden = false;
  renderRelationLinks(list, rels);
}

export async function workItem(): Promise<void> {
  const id = getQs("id");
  const iconEl = $<HTMLElement>("#work-item-icon");
  const titleEl = $<HTMLHeadingElement>("#work-item-title");
  const statusEl = $<HTMLSpanElement>("#work-item-status");
  const createdEl = $<HTMLSpanElement>("#work-item-created");
  const systemsEl = $<HTMLDivElement>("#work-item-systems");
  const bodyEl = $<HTMLElement>("#work-item-body");

  if (!id) {
    titleEl.textContent = "Missing id";
    renderError(bodyEl, "No work-item id supplied. Open one from the All work items list.");
    return;
  }

  try {
    const data = await api<WorkItemDetail>(`/api/work-item?id=${encodeURIComponent(id)}`);
    titleEl.textContent = data.title || data.slug;
    document.title = `${titleEl.textContent} · Stax`;

    statusEl.textContent = data.status;
    applyStatusClass(statusEl, data.status);
    statusEl.hidden = false;
    paintFlagIcon(iconEl, data.status, data.hasOpenTasks);
    applyRelativeTime(createdEl, data.created);

    systemsEl.replaceChildren();
    for (const sid of data.systems ?? []) {
      const link = tpl("tpl-system-link");
      const a = link.querySelector<HTMLAnchorElement>("a");
      if (!a) continue;
      a.href = `/system?id=${encodeURIComponent(sid)}`;
      a.textContent = sid;
      systemsEl.appendChild(link);
    }

    toggleRelationRow("work-item-superseded-by-row", "work-item-superseded-by", data.supersededBy);

    // HTML body comes from goldmark's safe rendering on the server side
    // (raw HTML in the markdown is escaped), so innerHTML is safe.
    bodyEl.innerHTML = data.html;
  } catch (err) {
    titleEl.textContent = "Work item not found";
    const msg = err instanceof Error ? err.message : String(err);
    renderError(bodyEl, `Request failed: ${msg}`);
  }
}
