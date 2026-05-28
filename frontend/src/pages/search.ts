export function search(): string {
  return `
    <section class="container py-l">
      <h4 class="mb-m">Search</h4>
      <div class="field label prefix border round mb-l">
        <i>search</i>
        <input type="search" id="search-input" autocomplete="off" autofocus />
        <label>Search by title, category, or keyword</label>
      </div>
      <p class="center-align padding small-text">Type to search across all essays.</p>
    </section>
  `;
}
