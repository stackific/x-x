import { THEME } from "../constants";

const { sidebarKey: SIDEBAR_KEY } = THEME;

function setExpanded(nav: HTMLElement, expanded: boolean): void {
  const btn = nav.querySelector("[aria-label='Toggle sidebar']");
  if (!btn) return;
  btn.setAttribute("aria-expanded", String(expanded));
  const icon = btn.querySelector("i");
  if (icon) icon.textContent = expanded ? "menu_open" : "menu";
}

function toggleSidebar(): void {
  const nav = document.querySelector<HTMLElement>("nav.left.l");
  if (!nav) return;
  const expanded = nav.classList.toggle("max");
  setExpanded(nav, expanded);
  localStorage.setItem(SIDEBAR_KEY, expanded ? "expanded" : "collapsed");
}

export function initSidebar(): void {
  document.getElementById("sidebar-toggle")?.addEventListener("click", toggleSidebar);

  if (localStorage.getItem(SIDEBAR_KEY) !== "expanded") return;
  const nav = document.querySelector<HTMLElement>("nav.left.l");
  if (!nav) return;
  nav.classList.add("max");
  setExpanded(nav, true);
}
