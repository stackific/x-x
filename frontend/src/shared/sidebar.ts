// Desktop sidebar (left rail) expand/collapse — width toggle + ARIA
// state + persisted preference. Wired in once per page from
// `bundle.ts`'s start() hook. Only the desktop rail (`nav.left.l`,
// where `.l` is BeerCSS's "large breakpoint visible" marker) is
// affected; the mobile drawer is a separate BeerCSS `<dialog>` driven
// by its own `data-ui` toggles in the markup.

import { THEME } from "../constants";

const { sidebarKey: SIDEBAR_KEY } = THEME;

// setExpanded mirrors the visual state onto the toggle button so the
// hamburger flips between "menu" (collapsed → "open it") and
// "menu_open" (expanded → "close it") and the `aria-expanded` value
// stays truthful for assistive tech. The button is found by its
// accessible label, not an id, because the same button sits inside
// a Handlebars partial that may render on any page.
function setExpanded(nav: HTMLElement, expanded: boolean): void {
  const btn = nav.querySelector("[aria-label='Toggle sidebar']");
  if (!btn) return;
  btn.setAttribute("aria-expanded", String(expanded));
  const icon = btn.querySelector("i");
  if (icon) icon.textContent = expanded ? "menu_open" : "menu";
}

// toggleSidebar is the click handler. BeerCSS's `.max` class on the
// rail expands it to its full label width; toggling that class is the
// entire visual flip. The new state is persisted to localStorage so
// the user's last preference reapplies on the next page load.
function toggleSidebar(): void {
  const nav = document.querySelector<HTMLElement>("nav.left.l");
  if (!nav) return;
  const expanded = nav.classList.toggle("max");
  setExpanded(nav, expanded);
  localStorage.setItem(SIDEBAR_KEY, expanded ? "expanded" : "collapsed");
}

// initSidebar wires the click handler and replays the persisted
// preference. We deliberately only expand-on-restore — collapsed is
// the default in CSS, so the "collapsed" branch is a no-op and the
// page renders without a layout flash even when the script runs late.
export function initSidebar(): void {
  document.getElementById("sidebar-toggle")?.addEventListener("click", toggleSidebar);

  if (localStorage.getItem(SIDEBAR_KEY) !== "expanded") return;
  const nav = document.querySelector<HTMLElement>("nav.left.l");
  if (!nav) return;
  nav.classList.add("max");
  setExpanded(nav, true);
}
