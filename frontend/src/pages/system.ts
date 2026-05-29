// /system?id=<id> — single-system detail page.
//
// Renders the named system's display name as the page header, then a
// row per work item whose frontmatter `systems:` array contains the id.
// Each row links to /scope?id=<work-item-slug>; the flag icon gets a
// `primary-text` tint when the work item has at least one open `- [ ]`
// task so a skim of the page surfaces in-flight work without
// requiring the reader to open every scope.
//
// Data flow:
//   /system?id=foo  →  GET /api/systems?id=foo  →  SystemDetail
//   Unknown id      →  server returns 404 → fetch throws → error branch
//   Missing ?id=    →  short-circuit with "No system id supplied" hint
//                      (no API call, prevents a noisy 404 in dev logs)
//
// Work-item order on the wire is filename-sort descending (newest first) —
// this page renders in receive order, no client-side sort.

import { api } from "../shared/api";
import { $, tpl } from "../shared/dom";
import { qs as getQs } from "../shared/qs";
import { applyRelativeTime } from "../shared/relative-time";
import { applyStatusClass, paintFlagIcon } from "../shared/status";

// Mirrors the Go-side planDetail in server.go. `hasOpenTasks` is the
// server's pre-computed verdict on the work-item body — true when at least
// one `- [ ]` task is unchecked. The body itself is not on the wire
// here (that belongs to /api/scope?id=<slug>); the page only shows
// row-level metadata.
type WorkItem = {
  slug: string;
  title: string;
  status: string;
  created: string;
  hasOpenTasks: boolean;
};

type SystemDetail = {
  id: string;
  name: string;
  workItems: WorkItem[];
};

// renderError stamps the shared `tpl-error` template into a host
// container with the supplied message. Kept inline (not imported)
// because every page renders its own error nodes against its own
// containers and the template id is page-local.
function renderError(host: HTMLElement, msg: string): void {
  const node = tpl("tpl-error");
  $('[data-slot="error"]', node).textContent = msg;
  host.replaceChildren(node);
}

export async function system(): Promise<void> {
  const id = getQs("id");
  const nameEl = $<HTMLHeadingElement>("#system-name");
  const workItemsEl = $<HTMLDivElement>("#system-work-items");

  // No id at all — render the missing-id hint and skip the round-trip.
  // Visiting /system without ?id= is usually a wrong-direction deep
  // link (someone copied the URL without the param); the hint points
  // them at /systems where they can pick one.
  if (!id) {
    nameEl.textContent = "Missing id";
    renderError(workItemsEl, "No system id supplied. Open a system from the All systems list.");
    return;
  }

  try {
    const data = await api<SystemDetail>(`/api/systems?id=${encodeURIComponent(id)}`);
    nameEl.textContent = data.name;
    document.title = `${data.name} · Stax`;

    if (!data.workItems.length) {
      // Known system with no work items — surface the dedicated empty-state
      // template so the reader sees "no work items yet" instead of a blank
      // panel.
      workItemsEl.replaceChildren(tpl("tpl-empty"));
      return;
    }

    // Build the rows into a fragment first, then swap them in with a
    // single replaceChildren — minimizes layout work compared to
    // appending one node at a time.
    const frag = document.createDocumentFragment();
    for (const p of data.workItems) {
      const node = tpl("tpl-work-item");
      const a = node.querySelector<HTMLAnchorElement>("a");
      if (a) a.href = `/scope?id=${encodeURIComponent(p.slug)}`;
      // Tint the flag icon via paintFlagIcon — error-text for
      // deprecated work items (do-not-use), else primary-text when there's
      // at least one open task. Same convention used on /scopes and
      // the home page's Latest-scopes section so the cue carries
      // across every list view.
      const icon = node.querySelector<HTMLElement>("i");
      if (icon) paintFlagIcon(icon, p.status, p.hasOpenTasks);
      $('[data-slot="title"]', node).textContent = p.title;
      const statusEl = $<HTMLSpanElement>('[data-slot="status"]', node);
      statusEl.textContent = p.status;
      applyStatusClass(statusEl, p.status);
      applyRelativeTime($('[data-slot="created"]', node), p.created);
      frag.appendChild(node);
    }
    workItemsEl.replaceChildren(frag);
  } catch (err) {
    // 404 (unknown id) and network failures land here together. The
    // title becomes "System not found" because a 404 is by far the
    // common case — a wrong slug in the URL.
    nameEl.textContent = "System not found";
    const msg = err instanceof Error ? err.message : String(err);
    renderError(workItemsEl, `Request failed: ${msg}`);
  }
}
