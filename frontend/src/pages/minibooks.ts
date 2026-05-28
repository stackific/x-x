type MinibookPlaceholder = {
  id: string;
  name: string;
  description: string;
  chaptersFound: number;
  total: number;
};

const PLACEHOLDER_MINIBOOKS: MinibookPlaceholder[] = [
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

function renderMinibook(m: MinibookPlaceholder): string {
  return `
    <a href="/minibooks/${m.id}" class="row padding round surface-variant wave no-elevate mb-s" style="text-decoration:none;">
      <i class="large" aria-hidden="true">menu_book</i>
      <div class="max ml-s">
        <h6>${m.name}</h6>
        <p class="small-text mt-t">${m.description}</p>
      </div>
      <span class="small-text">${m.chaptersFound} / ${m.total} chapters</span>
    </a>
  `;
}

export function minibooks(): string {
  const items = PLACEHOLDER_MINIBOOKS.map(renderMinibook).join("");
  return `
    <section class="container py-l">
      <h4 class="mb-m">Minibooks</h4>
      <p class="mb-l">Multi-chapter minibooks designed to be read in order, from first chapter to last.</p>
      ${items}
    </section>
  `;
}
