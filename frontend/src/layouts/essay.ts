export type EssayLayoutProps = {
  title: string;
  category: string;
  categoryName: string;
  parentCategory?: { id: string; name: string };
  minibook?: { id: string; name: string };
  createdAt: string;
  thumbnail?: string;
};

function formatLongDate(iso: string): string {
  return new Date(iso).toLocaleDateString("en-US", {
    year: "numeric",
    month: "long",
    day: "numeric",
  });
}

export function essayLayout(props: EssayLayoutProps, content: string): string {
  const { title, category, categoryName, parentCategory, minibook, createdAt, thumbnail } = props;
  const cover = thumbnail || "/default-cover.jpg";
  const dateFormatted = formatLongDate(createdAt);
  const parentChip = parentCategory
    ? `<a href="/categories/${parentCategory.id}" class="chip small round no-elevate">
         <i>folder</i>
         <span>${parentCategory.name}</span>
       </a>`
    : "";
  const minibookChip = minibook
    ? `<a href="/minibooks/${minibook.id}" class="chip small round tertiary-container no-elevate" title="${minibook.name}">
         <i>menu_book</i>
         <span>${minibook.name}</span>
       </a>`
    : "";
  return `
    <article class="container py-l">
      <img class="responsive round large" src="${cover}" alt="${title}" loading="eager" data-essay-cover />
      <h3 class="mt-m">${title}</h3>
      <div class="mt-s small-text essay-meta">
        ${parentChip}
        <a href="/categories/${category}" class="chip small round fill">
          <i>category</i>
          <span>${categoryName}</span>
        </a>
        ${minibookChip}
        <span>${dateFormatted}</span>
      </div>
      <hr class="mt-m" />
      <div class="mt-l essay-content">
        ${content}
      </div>
    </article>
  `;
}
