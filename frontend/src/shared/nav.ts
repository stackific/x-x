export function syncActiveNav(): void {
  const active = document.body.dataset.active ?? "";
  for (const el of document.querySelectorAll<HTMLAnchorElement>("[data-nav-link]")) {
    const key = el.dataset.activeKey ?? "";
    el.classList.toggle("active", key !== "" && key === active);
  }
}
