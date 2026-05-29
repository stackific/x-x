// Home page (`/`) — two summary cards + latest-scopes feed.
//
// Layout: a Systems count card (link to /systems) and a Scopes count
// card (link to /scopes), then a row-per-scope list of the most
// recent N plans, descending. Both cards show `0` if the project is
// freshly initialized; the latest-scopes section shows the dedicated
// empty-state template.
//
// Why two parallel requests (Promise.allSettled, not Promise.all):
//   - The counts and the latest list come from different endpoints.
//     Firing them together cuts the page's wall-clock latency to
//     `max(t_stats, t_scopes)` instead of the sequential sum.
//   - allSettled (not all) means one slow/failed endpoint doesn't
//     blank the other: a 500 on /api/scopes still leaves the count
//     cards filled in from /api/stats, and vice versa.
//
// The Go server treats both endpoints as 200-with-empty for a project
// with no systems / scopes, so the empty-project path doesn't surface
// here as an error.

import { api } from "../shared/api";
import { $, tpl } from "../shared/dom";
import { applyRelativeTime } from "../shared/relative-time";
import { applyStatusClass, paintFlagIcon } from "../shared/status";

// Mirrors statsResponse in server.go. version isn't rendered today;
// it's on the wire for the dual-purpose liveness probe and is left
// available here for a future "running stax vN.M" footer.
type Stats = { version: string; systems: number; scopes: number };

// Mirrors scopeListItem in server.go. The page renders a subset of
// these fields; keeping the type complete makes it self-documenting
// when someone needs to add another field to a row.
type Scope = {
  slug: string;
  title: string;
  status: string;
  created: string;
  systems: string[];
  hasOpenTasks: boolean;
};

type ScopesResponse = { scopes: Scope[] };

// Server returns ALL scopes (descending). We slice client-side so the
// home page stays fast on big projects without adding a query
// parameter the server has to honor.
const LATEST_LIMIT = 10;

function renderError(host: HTMLElement, msg: string): void {
  const node = tpl("tpl-error");
  $('[data-slot="error"]', node).textContent = msg;
  host.replaceChildren(node);
}

// renderSystems builds the per-scope chip row of system links. Each
// chip carries an inner click-stopper because the parent <a class="row">
// also targets a URL (/scope?id=<slug>) — without stopPropagation a
// click on the chip would bubble to the row and open the scope
// instead of the system.
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

// renderLatestScopes stamps up to LATEST_LIMIT rows from the supplied
// list. Status chip gets the lifecycle tint via applyStatusClass; the
// flag icon's tint comes from paintFlagIcon — error-text on deprecated
// rows, else primary-text when there's at least one open `- [ ]` task.
// Same conventions as /scopes and /system — the cue carries across
// every list view so the user can scan for in-flight (and do-not-use)
// work without remembering which page enforces which rule.
function renderLatestScopes(host: HTMLElement, scopes: Scope[]): void {
  if (!scopes.length) {
    host.replaceChildren(tpl("tpl-empty"));
    return;
  }
  const frag = document.createDocumentFragment();
  for (const s of scopes.slice(0, LATEST_LIMIT)) {
    const node = tpl("tpl-scope");
    const card = node.querySelector<HTMLAnchorElement>("a");
    if (card) card.href = `/scope?id=${encodeURIComponent(s.slug)}`;
    const icon = node.querySelector<HTMLElement>("i");
    if (icon) paintFlagIcon(icon, s.status, s.hasOpenTasks);
    $('[data-slot="title"]', node).textContent = s.title || s.slug;
    applyRelativeTime($('[data-slot="created"]', node), s.created);
    const statusEl = $<HTMLSpanElement>('[data-slot="status"]', node);
    statusEl.textContent = s.status;
    applyStatusClass(statusEl, s.status);
    renderSystems($<HTMLDivElement>('[data-slot="systems"]', node), s.systems);
    frag.appendChild(node);
  }
  host.replaceChildren(frag);
}

export async function home(): Promise<void> {
  const sysCount = $<HTMLHeadingElement>("#count-systems");
  const scopeCount = $<HTMLHeadingElement>("#count-scopes");
  const latestHost = $<HTMLDivElement>("#latest-scopes");

  const [statsResult, scopesResult] = await Promise.allSettled([
    api<Stats>("/api/stats"),
    api<ScopesResponse>("/api/scopes"),
  ]);

  // Stats endpoint feeds the two count cards. On failure we still
  // render zeros — the cards are clickable links into the dedicated
  // list pages where the user can see (and diagnose) the real error.
  if (statsResult.status === "fulfilled") {
    sysCount.textContent = String(statsResult.value.systems);
    scopeCount.textContent = String(statsResult.value.scopes);
  } else {
    sysCount.textContent = "0";
    scopeCount.textContent = "0";
  }

  // Latest-scopes failure becomes a visible error message in the
  // dedicated section; the cards above are independent so the page
  // is partially useful even when this endpoint is down.
  if (scopesResult.status === "fulfilled") {
    renderLatestScopes(latestHost, scopesResult.value.scopes ?? []);
  } else {
    renderError(latestHost, `Failed to load scopes: ${(scopesResult.reason as Error).message}`);
  }
}
