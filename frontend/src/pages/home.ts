import { type EssayCardProps, essayCard } from "../components/essay-card";

const PLACEHOLDER_CARDS: EssayCardProps[] = Array.from({ length: 9 }, (_, i) => ({
  slug: `placeholder-${i + 1}`,
  title: "Sample essay title for layout review",
  category: "sample",
  categoryName: "Sample category",
  createdAt: "2026-01-01",
  excerpt: "Short excerpt placeholder text to demonstrate card layout and rhythm.",
  essayType: i % 3 === 0 ? "chapter" : "essay",
}));

export function home(): string {
  const cards = PLACEHOLDER_CARDS.map(essayCard).join("");
  return `
    <section class="container py-l">
      <div class="row middle-align mb-m">
        <h4 class="max">Latest</h4>
        <div class="field suffix small round border no-margin home-filter-field">
          <select id="home-filter" aria-label="Filter content">
            <option value="all">All</option>
            <option value="essays">Standalone essays</option>
            <option value="chapters">Minibook chapters</option>
          </select>
          <i>arrow_drop_down</i>
        </div>
      </div>
      <div id="essays-section">
        <div class="grid" id="essays-grid">${cards}</div>
        <div id="scroll-sentinel" class="padding center-align">
          <progress class="circle"></progress>
        </div>
        <div id="scroll-end" class="padding center-align" style="display:none;">
          <p class="small-text">You've reached the end.</p>
        </div>
      </div>
    </section>
  `;
}
