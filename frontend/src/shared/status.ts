// applyStatusClass tints a status element with the BeerCSS color
// token that matches the plan's lifecycle stage so the /scopes,
// /system, /scope, and home pages all surface valid / superseded /
// deprecated at a glance. The helper adapts to the element's current
// classes so callers can use either a chip (background tint via the
// `-container` token) or a plain text span (text tint via the `-text`
// token) without picking a class name themselves:
//
//   - valid       → no override (default look)
//   - superseded  → tertiary token (history, not current)
//   - deprecated  → error token     (warning, do not use)
//
// Removes any prior status class so reusing the same node across
// renders doesn't accumulate state.
export function applyStatusClass(el: HTMLElement, status: string): void {
  el.classList.remove("tertiary-text", "error-text", "tertiary-container", "error-container");
  if (status !== "superseded" && status !== "deprecated") {
    return;
  }
  const tone = status === "superseded" ? "tertiary" : "error";
  const variant = el.classList.contains("chip") ? "container" : "text";
  el.classList.add(`${tone}-${variant}`);
}
