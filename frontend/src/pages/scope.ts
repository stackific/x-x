import { api } from "../shared/api";
import { $, tpl } from "../shared/dom";
import { qs as getQs } from "../shared/qs";
import { relativeTime } from "../shared/relative-time";
import { applyStatusClass } from "../shared/status";

// Mirrors the Go-side scopeDetail in server.go: a single plan's
// frontmatter fields plus the markdown body pre-rendered to HTML
// server-side (goldmark with HTML escaping enabled, so innerHTML is
// safe here). supersededBy carries the slug + title of every newer
// plan that replaced this one, so the UI can render human-readable
// chips instead of raw filename slugs.
type ScopeRelation = { slug: string; title: string };

type ScopeDetail = {
  slug: string;
  title: string;
  status: string;
  created: string;
  systems: string[];
  supersedes: ScopeRelation[] | null;
  supersededBy: ScopeRelation[] | null;
  html: string;
};

function renderError(host: HTMLElement, msg: string): void {
  const node = tpl("tpl-error");
  $('[data-slot="error"]', node).textContent = msg;
  host.replaceChildren(node);
}

function renderRelationLinks(host: HTMLElement, rels: readonly ScopeRelation[]): void {
  host.replaceChildren();
  for (const rel of rels) {
    const link = tpl("tpl-scope-link");
    const a = link.querySelector<HTMLAnchorElement>("a");
    if (!a) continue;
    a.href = `/scope?id=${encodeURIComponent(rel.slug)}`;
    a.textContent = rel.title || rel.slug;
    a.title = rel.slug;
    host.appendChild(link);
  }
}

function toggleRelationRow(rowID: string, listID: string, rels: ScopeRelation[] | null): void {
  const row = $<HTMLDivElement>(`#${rowID}`);
  const list = $<HTMLDivElement>(`#${listID}`);
  if (!rels || !rels.length) {
    row.hidden = true;
    list.replaceChildren();
    return;
  }
  row.hidden = false;
  renderRelationLinks(list, rels);
}

export async function scope(): Promise<void> {
  const id = getQs("id");
  const titleEl = $<HTMLHeadingElement>("#scope-title");
  const statusEl = $<HTMLSpanElement>("#scope-status");
  const createdEl = $<HTMLSpanElement>("#scope-created");
  const systemsEl = $<HTMLDivElement>("#scope-systems");
  const bodyEl = $<HTMLElement>("#scope-body");

  if (!id) {
    titleEl.textContent = "Missing id";
    renderError(bodyEl, "No scope id supplied. Open a scope from the All scopes list.");
    return;
  }

  try {
    const data = await api<ScopeDetail>(`/api/scope?id=${encodeURIComponent(id)}`);
    titleEl.textContent = data.title || data.slug;
    document.title = `${titleEl.textContent} · Stax`;

    statusEl.textContent = data.status;
    applyStatusClass(statusEl, data.status);
    statusEl.hidden = false;
    createdEl.textContent = relativeTime(data.created);

    systemsEl.replaceChildren();
    for (const sid of data.systems ?? []) {
      const link = tpl("tpl-system-link");
      const a = link.querySelector<HTMLAnchorElement>("a");
      if (!a) continue;
      a.href = `/system?id=${encodeURIComponent(sid)}`;
      a.textContent = sid;
      systemsEl.appendChild(link);
    }

    toggleRelationRow("scope-superseded-by-row", "scope-superseded-by", data.supersededBy);

    // HTML body comes from goldmark's safe rendering on the server side
    // (raw HTML in the markdown is escaped), so innerHTML is safe.
    bodyEl.innerHTML = data.html;
  } catch (err) {
    titleEl.textContent = "Scope not found";
    const msg = err instanceof Error ? err.message : String(err);
    renderError(bodyEl, `Request failed: ${msg}`);
  }
}
