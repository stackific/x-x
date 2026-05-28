// /system?id=<id> — single-system detail page.
//
// Renders the named system's display name as the page header, then a
// row per plan whose frontmatter `systems:` array contains the id.
// Each row links to /scope?id=<plan-slug>; the flag icon gets a
// `primary-text` tint when the plan has at least one open `- [ ]`
// task so a skim of the page surfaces in-flight work without
// requiring the reader to open every scope.
//
// Data flow:
//   /system?id=foo  →  GET /api/systems?id=foo  →  SystemDetail
//   Unknown id      →  server returns 404 → fetch throws → error branch
//   Missing ?id=    →  short-circuit with "No system id supplied" hint
//                      (no API call, prevents a noisy 404 in dev logs)
//
// Plan order on the wire is filename-sort descending (newest first) —
// this page renders in receive order, no client-side sort.

import { api } from "../shared/api";
import { $, tpl } from "../shared/dom";
import { qs as getQs } from "../shared/qs";
import { relativeTime } from "../shared/relative-time";
import { applyStatusClass } from "../shared/status";

// Mirrors the Go-side planDetail in server.go. `hasOpenTasks` is the
// server's pre-computed verdict on the plan body — true when at least
// one `- [ ]` task is unchecked. The body itself is not on the wire
// here (that belongs to /api/scope?id=<slug>); the page only shows
// row-level metadata.
type Plan = {
  slug: string;
  title: string;
  status: string;
  created: string;
  hasOpenTasks: boolean;
};

type SystemDetail = {
  id: string;
  name: string;
  plans: Plan[];
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
  const plansEl = $<HTMLDivElement>("#system-plans");

  // No id at all — render the missing-id hint and skip the round-trip.
  // Visiting /system without ?id= is usually a wrong-direction deep
  // link (someone copied the URL without the param); the hint points
  // them at /systems where they can pick one.
  if (!id) {
    nameEl.textContent = "Missing id";
    renderError(plansEl, "No system id supplied. Open a system from the All systems list.");
    return;
  }

  try {
    const data = await api<SystemDetail>(`/api/systems?id=${encodeURIComponent(id)}`);
    nameEl.textContent = data.name;
    document.title = `${data.name} · Stax`;

    if (!data.plans.length) {
      // Known system with no plans — surface the dedicated empty-state
      // template so the reader sees "no plans yet" instead of a blank
      // panel.
      plansEl.replaceChildren(tpl("tpl-empty"));
      return;
    }

    // Build the rows into a fragment first, then swap them in with a
    // single replaceChildren — minimizes layout work compared to
    // appending one node at a time.
    const frag = document.createDocumentFragment();
    for (const p of data.plans) {
      const node = tpl("tpl-plan");
      const a = node.querySelector<HTMLAnchorElement>("a");
      if (a) a.href = `/scope?id=${encodeURIComponent(p.slug)}`;
      // Tint the flag icon when this plan has open tasks. Same
      // primary-text convention used on /scopes, /search, and the
      // home page's Latest-scopes section so the cue carries across
      // every list view.
      if (p.hasOpenTasks) {
        const icon = node.querySelector<HTMLElement>("i");
        if (icon) icon.classList.add("primary-text");
      }
      $('[data-slot="title"]', node).textContent = p.title;
      const statusEl = $<HTMLSpanElement>('[data-slot="status"]', node);
      statusEl.textContent = p.status;
      applyStatusClass(statusEl, p.status);
      $('[data-slot="created"]', node).textContent = relativeTime(p.created);
      frag.appendChild(node);
    }
    plansEl.replaceChildren(frag);
  } catch (err) {
    // 404 (unknown id) and network failures land here together. The
    // title becomes "System not found" because a 404 is by far the
    // common case — a wrong slug in the URL.
    nameEl.textContent = "System not found";
    const msg = err instanceof Error ? err.message : String(err);
    renderError(plansEl, `Request failed: ${msg}`);
  }
}
