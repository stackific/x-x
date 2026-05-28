import { api } from "../shared/api";
import { $, tpl } from "../shared/dom";
import { qs as getQs } from "../shared/qs";
import { relativeTime } from "../shared/relative-time";

// Mirrors the Go-side scopeDetail in server.go: a single plan's
// frontmatter fields plus the markdown body pre-rendered to HTML
// server-side (goldmark with HTML escaping enabled, so innerHTML is
// safe here).
type ScopeDetail = {
  slug: string;
  title: string;
  status: string;
  created: string;
  systems: string[];
  html: string;
};

function renderError(host: HTMLElement, msg: string): void {
  const node = tpl("tpl-error");
  $('[data-slot="error"]', node).textContent = msg;
  host.replaceChildren(node);
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

    // HTML body comes from goldmark's safe rendering on the server side
    // (raw HTML in the markdown is escaped), so innerHTML is safe.
    bodyEl.innerHTML = data.html;
  } catch (err) {
    titleEl.textContent = "Scope not found";
    const msg = err instanceof Error ? err.message : String(err);
    renderError(bodyEl, `Request failed: ${msg}`);
  }
}
