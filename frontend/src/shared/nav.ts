// Sidebar / mobile-nav active-link highlighter. Runs once on every
// page from `bundle.ts`'s start() hook, after the DOM is ready.
//
// Why an attribute-driven match (not a `location.pathname` compare):
//   - A page can advertise a *logical* nav target that differs from
//     its URL — `/scope?id=<slug>` sets `data-active="scopes"` so the
//     sidebar "Scopes" entry stays highlighted while the user reads
//     a single plan. Doing this purely from `location.pathname` would
//     either highlight nothing on detail pages or require the
//     dispatcher to special-case each route.
//   - Layout is owned by HTML; only HTML sets `data-active` (via the
//     Handlebars layout's block-helper call). TS just diffs.
//
// Contract:
//   - Body carries `data-active="<key>"`. Empty / missing means "no
//     highlight" (the 404 page leaves the attribute empty so no row
//     lights up).
//   - Every nav anchor carries `data-nav-link` and `data-active-key="<key>"`.
//     The `data-nav-link` marker keeps this from accidentally
//     highlighting other anchors (footer links, in-content links to
//     the same routes) that aren't part of the rail.
//   - A row gets `.active` iff its `data-active-key` is non-empty AND
//     matches body's `data-active`. Non-empty guard avoids lighting
//     up every link whose attribute happens to be absent when body
//     is also empty.
export function syncActiveNav(): void {
  const active = document.body.dataset.active ?? "";
  for (const el of document.querySelectorAll<HTMLAnchorElement>("[data-nav-link]")) {
    const key = el.dataset.activeKey ?? "";
    el.classList.toggle("active", key !== "" && key === active);
  }
}
