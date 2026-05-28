import { $, tpl } from "../shared/dom";
import { qs as getQs } from "../shared/qs";

type Result = { id: string; title: string; excerpt: string; date: string };

function render(items: Result[], host: HTMLElement, hint: HTMLElement): void {
  if (!items.length) {
    host.replaceChildren();
    hint.style.display = "";
    return;
  }
  hint.style.display = "none";
  const frag = document.createDocumentFragment();
  for (const r of items) {
    const node = tpl("tpl-result");
    const a = node.querySelector<HTMLAnchorElement>("a");
    if (a) a.href = `/essay?slug=${encodeURIComponent(r.id)}`;
    $('[data-slot="title"]', node).textContent = r.title;
    $('[data-slot="excerpt"]', node).textContent = r.excerpt;
    $('[data-slot="date"]', node).textContent = r.date;
    frag.appendChild(node);
  }
  host.replaceChildren(frag);
}

export function search(): void {
  const input = $<HTMLInputElement>("#search-input");
  const results = $<HTMLDivElement>("#search-results");
  const hint = $<HTMLParagraphElement>("#search-hint");

  const initial = getQs("q");
  if (initial) input.value = initial;

  const run = (q: string): void => {
    // TODO: when /api/search is ready:
    //   const items = await api<Result[]>(`/api/search?q=${encodeURIComponent(q)}`);
    //   render(items, results, hint);
    if (!q) {
      render([], results, hint);
      return;
    }
    render([], results, hint);
  };

  let timer: number | undefined;
  input.addEventListener("input", () => {
    window.clearTimeout(timer);
    timer = window.setTimeout(() => run(input.value.trim()), 200);
  });

  if (initial) run(initial.trim());
}
