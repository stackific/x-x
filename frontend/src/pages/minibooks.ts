import { $, tpl } from "../shared/dom";

type Minibook = {
  id: string;
  name: string;
  description: string;
  chaptersFound: number;
  total: number;
};

const PLACEHOLDER_MINIBOOKS: Minibook[] = [
  {
    id: "sample-minibook-one",
    name: "Sample minibook one",
    description: "Short description of the minibook to demonstrate row layout.",
    chaptersFound: 4,
    total: 10,
  },
  {
    id: "sample-minibook-two",
    name: "Sample minibook two",
    description: "Another minibook description placeholder.",
    chaptersFound: 7,
    total: 7,
  },
];

export function minibooks(): void {
  const host = $<HTMLDivElement>("#minibooks-list");
  const frag = document.createDocumentFragment();
  for (const m of PLACEHOLDER_MINIBOOKS) {
    const node = tpl("tpl-minibook");
    const a = node.querySelector<HTMLAnchorElement>("a");
    if (a) a.href = `/minibooks?id=${encodeURIComponent(m.id)}`;
    $('[data-slot="name"]', node).textContent = m.name;
    $('[data-slot="description"]', node).textContent = m.description;
    $('[data-slot="progress"]', node).textContent = `${m.chaptersFound} / ${m.total} chapters`;
    frag.appendChild(node);
  }
  host.replaceChildren(frag);
}
