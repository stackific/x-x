// Home page (`/`) — two summary cards + latest-work-items feed.
//
// Layout: a Systems count card (link to /systems) and a Work items count
// card (link to /work-items), then a row-per-work-item list of the most
// recent N work items, descending. Both cards show `0` if the project is
// freshly initialized; the latest-work-items section shows the dedicated
// empty-state template.
//
// Why two parallel requests (Promise.allSettled, not Promise.all):
//   - The counts and the latest list come from different endpoints.
//     Firing them together cuts the page's wall-clock latency to
//     `max(t_stats, t_work-items)` instead of the sequential sum.
//   - allSettled (not all) means one slow/failed endpoint doesn't
//     blank the other: a 500 on /api/work-items still leaves the count
//     cards filled in from /api/stats, and vice versa.
//
// The Go server treats both endpoints as 200-with-empty for a project
// with no systems / work items, so the empty-project path doesn't surface
// here as an error.

import { api } from "../shared/api";
import { $, tpl } from "../shared/dom";
import { applyRelativeTime } from "../shared/relative-time";
import { applyStatusClass, paintFlagIcon } from "../shared/status";

// Mirrors statsResponse in server.go. version isn't rendered today;
// it's on the wire for the dual-purpose liveness probe and is left
// available here for a future "running stax vN.M" footer.
type Stats = { version: string; systems: number; workItems: number };

// Mirrors workItemListItem in server.go. The page renders a subset of
// these fields; keeping the type complete makes it self-documenting
// when someone needs to add another field to a row.
type WorkItem = {
  slug: string;
  title: string;
  status: string;
  created: string;
  systems: string[];
  hasOpenTasks: boolean;
};

type WorkItemsResponse = { workItems: WorkItem[] };

// Server returns ALL work items (descending). We slice client-side so the
// home page stays fast on big projects without adding a query
// parameter the server has to honor.
const LATEST_LIMIT = 10;

function renderError(host: HTMLElement, msg: string): void {
  const node = tpl("tpl-error");
  $('[data-slot="error"]', node).textContent = msg;
  host.replaceChildren(node);
}

// renderSystems builds the per-work-item chip row of system links. Each
// chip carries an inner click-stopper because the parent <a class="row">
// also targets a URL (/work-item?id=<slug>) — without stopPropagation a
// click on the chip would bubble to the row and open the work item
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

// renderLatestWorkItems stamps up to LATEST_LIMIT rows from the supplied
// list. Status chip gets the lifecycle tint via applyStatusClass; the
// flag icon's tint comes from paintFlagIcon — error-text on deprecated
// rows, else primary-text when there's at least one open `- [ ]` task.
// Same conventions as /work-items and /system — the cue carries across
// every list view so the user can scan for in-flight (and do-not-use)
// work without remembering which page enforces which rule.
function renderLatestWorkItems(host: HTMLElement, items: WorkItem[]): void {
  if (!items.length) {
    host.replaceChildren(tpl("tpl-empty"));
    return;
  }
  const frag = document.createDocumentFragment();
  for (const s of items.slice(0, LATEST_LIMIT)) {
    const node = tpl("tpl-work-item");
    const card = node.querySelector<HTMLAnchorElement>("a");
    if (card) card.href = `/work-item?id=${encodeURIComponent(s.slug)}`;
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
  const workItemCount = $<HTMLHeadingElement>("#count-work-items");
  const latestHost = $<HTMLDivElement>("#latest-work-items");

  const [statsResult, listResult] = await Promise.allSettled([
    api<Stats>("/api/stats"),
    api<WorkItemsResponse>("/api/work-items"),
  ]);

  // Stats endpoint feeds the two count cards. On failure we still
  // render zeros — the cards are clickable links into the dedicated
  // list pages where the user can see (and diagnose) the real error.
  if (statsResult.status === "fulfilled") {
    sysCount.textContent = String(statsResult.value.systems);
    workItemCount.textContent = String(statsResult.value.workItems);
  } else {
    sysCount.textContent = "0";
    workItemCount.textContent = "0";
  }

  // Latest-work-items failure becomes a visible error message in the
  // dedicated section; the cards above are independent so the page
  // is partially useful even when this endpoint is down.
  if (listResult.status === "fulfilled") {
    renderLatestWorkItems(latestHost, listResult.value.workItems ?? []);
  } else {
    renderError(latestHost, `Failed to load work items: ${(listResult.reason as Error).message}`);
  }
}
