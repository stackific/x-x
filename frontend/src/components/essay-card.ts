export type EssayCardProps = {
  slug: string;
  title: string;
  category: string;
  categoryName: string;
  createdAt: string;
  excerpt: string;
  thumbnail?: string;
  essayType?: "essay" | "chapter";
};

const DEFAULT_THUMB = "/default-cover.jpg";

function formatDate(iso: string): string {
  return new Date(iso).toLocaleDateString("en-US", {
    year: "numeric",
    month: "short",
    day: "numeric",
  });
}

export function essayCard(props: EssayCardProps): string {
  const {
    slug,
    title,
    category,
    categoryName,
    createdAt,
    excerpt,
    thumbnail,
    essayType = "essay",
  } = props;
  const thumbSrc = thumbnail || `/thumbnails/${slug}.webp`;
  const essayUrl = `/essays/${slug}`;
  const dateFormatted = formatDate(createdAt);
  return `
    <div class="s12 m6 l4" data-essay-card data-essay-type="${essayType}">
      <article class="no-padding round surface no-elevate essay-card-article">
        <a href="${essayUrl}" style="display:block;">
          <img class="responsive" src="${thumbSrc}" alt="${title}" width="600" height="340" loading="lazy"
            onerror="this.onerror=null;this.src='${DEFAULT_THUMB}'" />
        </a>
        <div class="padding">
          <a href="${essayUrl}" class="essay-card-title">
            <h6 class="small">${title}</h6>
          </a>
          <p class="small-text mt-t">${excerpt}</p>
          <div class="card-meta mt-s">
            <a href="/categories/${category}" class="chip small round no-elevate" onclick="event.stopPropagation()">
              <i>category</i>
              <span>${categoryName}</span>
            </a>
            <span class="small-text">${dateFormatted}</span>
          </div>
        </div>
      </article>
    </div>
  `;
}
