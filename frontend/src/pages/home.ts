import { api } from "../shared/api";
import { $, tpl } from "../shared/dom";
import { relativeTime } from "../shared/relative-time";

type Stats = { version: string; systems: number; scopes: number };

type Scope = {
  slug: string;
  title: string;
  status: string;
  created: string;
  systems: string[];
};

type ScopesResponse = { scopes: Scope[] };

const LATEST_LIMIT = 10;

function renderError(host: HTMLElement, msg: string): void {
  const node = tpl("tpl-error");
  $('[data-slot="error"]', node).textContent = msg;
  host.replaceChildren(node);
}

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
    $('[data-slot="title"]', node).textContent = s.title || s.slug;
    $('[data-slot="created"]', node).textContent = relativeTime(s.created);
    $('[data-slot="status"]', node).textContent = s.status;
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

  if (statsResult.status === "fulfilled") {
    sysCount.textContent = String(statsResult.value.systems);
    scopeCount.textContent = String(statsResult.value.scopes);
  } else {
    sysCount.textContent = "0";
    scopeCount.textContent = "0";
  }

  if (scopesResult.status === "fulfilled") {
    renderLatestScopes(latestHost, scopesResult.value.scopes ?? []);
  } else {
    renderError(latestHost, `Failed to load scopes: ${(scopesResult.reason as Error).message}`);
  }
}
