type CategoryPlaceholder = {
  id: string;
  name: string;
  count: number;
  children?: { id: string; name: string; count: number }[];
};

const PLACEHOLDER_CATEGORIES: CategoryPlaceholder[] = [
  {
    id: "ai",
    name: "AI",
    count: 12,
    children: [
      { id: "ai-evals", name: "Evals", count: 3 },
      { id: "ai-agents", name: "Agents", count: 5 },
      { id: "ai-rag", name: "RAG", count: 4 },
    ],
  },
  { id: "engineering", name: "Engineering", count: 8 },
  { id: "design", name: "Design", count: 5 },
];

function renderCategory(cat: CategoryPlaceholder): string {
  if (cat.children && cat.children.length > 0) {
    const children = cat.children
      .map(
        (child) => `
          <a href="/categories/${child.id}" class="chip small round no-elevate">
            <i aria-hidden="true">category</i>
            <span>${child.name}</span>
            <span class="small-text">(${child.count})</span>
          </a>
        `,
      )
      .join("");
    return `
      <details class="mb-l" open>
        <summary class="padding round surface-variant bold">
          <i class="mr-s" aria-hidden="true">folder</i>
          ${cat.name}
          <span class="small-text ml-s">(${cat.count})</span>
        </summary>
        <div class="pl-l mt-t category-children">${children}</div>
      </details>
    `;
  }
  return `
    <a href="/categories/${cat.id}" class="row padding round surface-variant wave mb-l bold">
      <i class="mr-s" aria-hidden="true">category</i>
      <span class="max">${cat.name}</span>
      <span class="small-text">(${cat.count})</span>
    </a>
  `;
}

export function categories(): string {
  const items = PLACEHOLDER_CATEGORIES.map(renderCategory).join("");
  return `
    <section class="container py-l">
      <h4 class="mb-m">Categories</h4>
      ${items}
    </section>
  `;
}
