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

// paintFlagIcon applies the flag-icon coloring convention used by every
// scope-list view (/scopes, /, /system?id=) and the /scope?id= title.
// Three cues stack on the same icon, so the helper encodes the
// precedence in one place — lifecycle decoration outranks the
// in-flight signal because a non-current plan's open tasks are stale
// by definition:
//
//   - deprecated     → error-text     (do-not-use)
//   - superseded     → tertiary-text  (history, replaced by a newer plan)
//   - has open task  → primary-text   (in-flight work)
//   - else           → no override    (default look)
//
// Mirrors applyStatusClass's lifecycle palette so the chip and the
// icon never disagree on a row. Removes the three managed classes
// first so reusing the same node across renders doesn't accumulate
// state. Companion to applyStatusClass: status chips vs. flag icons
// get different color cues, but both route through this module so
// adding a new lifecycle stage is a one-file change.
export function paintFlagIcon(icon: HTMLElement, status: string, hasOpenTasks: boolean): void {
  icon.classList.remove("error-text", "tertiary-text", "primary-text");
  if (status === "deprecated") {
    icon.classList.add("error-text");
    return;
  }
  if (status === "superseded") {
    icon.classList.add("tertiary-text");
    return;
  }
  if (hasOpenTasks) {
    icon.classList.add("primary-text");
  }
}
