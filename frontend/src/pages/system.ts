import { api } from "../shared/api";
import { $, tpl } from "../shared/dom";
import { qs as getQs } from "../shared/qs";
import { relativeTime } from "../shared/relative-time";
import { applyStatusClass } from "../shared/status";

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

function renderError(host: HTMLElement, msg: string): void {
  const node = tpl("tpl-error");
  $('[data-slot="error"]', node).textContent = msg;
  host.replaceChildren(node);
}

export async function system(): Promise<void> {
  const id = getQs("id");
  const nameEl = $<HTMLHeadingElement>("#system-name");
  const plansEl = $<HTMLDivElement>("#system-plans");

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
      plansEl.replaceChildren(tpl("tpl-empty"));
      return;
    }

    const frag = document.createDocumentFragment();
    for (const p of data.plans) {
      const node = tpl("tpl-plan");
      const a = node.querySelector<HTMLAnchorElement>("a");
      if (a) a.href = `/scope?id=${encodeURIComponent(p.slug)}`;
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
    nameEl.textContent = "System not found";
    const msg = err instanceof Error ? err.message : String(err);
    renderError(plansEl, `Request failed: ${msg}`);
  }
}
