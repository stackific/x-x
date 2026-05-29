// Light/dark theme + Material Dynamic palette seed. Wired in once per
// page from `bundle.ts`'s start() hook, before any page-specific
// init — so when a page renders it already has the right `body.dark`
// class and the M3 palette resolved against the seed color.
//
// Behaviour:
//   - Seed the dynamic palette with a fixed color (THEME.seedColor)
//     so the M3 tokens (primary, secondary, tertiary, error, surface
//     variants) resolve identically across pages.
//   - Pick the initial mode in this order: explicit user choice
//     persisted to localStorage > OS `prefers-color-scheme` > light.
//     Persisting a user override means a manual toggle wins forever
//     until the user toggles back; OS preference only matters on a
//     never-toggled session.
//   - Mirror the current mode onto every `[data-theme-toggle]` button's
//     icon (sun on dark, moon on light) so the button always shows
//     what the click WILL do, not what's currently active. The mobile
//     drawer and desktop rail each render their own toggle button —
//     both are picked up by the same `[data-theme-toggle]` query.

import ui from "beercss";
import { THEME } from "../constants";

const { seedColor: SEED_COLOR, storageKey: THEME_KEY } = THEME;

// syncThemeIcons keeps every theme-toggle button visually consistent
// with the current mode. Called from both the initial-load path and
// the click handler, so a manual toggle and a page navigation render
// the same icon for the same mode.
function syncThemeIcons(): void {
  const isDark = document.body.classList.contains("dark");
  const icon = isDark ? "light_mode" : "dark_mode";
  for (const el of document.querySelectorAll("[data-theme-toggle] i")) {
    el.textContent = icon;
  }
}

// toggleTheme flips the mode, persists the new choice, then resyncs
// the icons. `ui("mode", ...)` is BeerCSS's mode-switch API — it adds
// or removes `body.dark` and re-evaluates the palette in one call.
function toggleTheme(): void {
  const isDark = document.body.classList.contains("dark");
  const next = isDark ? "light" : "dark";
  ui("mode", next);
  localStorage.setItem(THEME_KEY, next);
  syncThemeIcons();
}

// initTheme runs once per page. Order matters: seed the palette first
// (so any subsequent `ui("mode", ...)` has tokens to flip against),
// then apply the resolved mode, then bind click handlers.
export function initTheme(): void {
  ui("theme", SEED_COLOR);
  const saved = localStorage.getItem(THEME_KEY);
  if (saved === "light" || saved === "dark") {
    ui("mode", saved);
  } else {
    const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
    ui("mode", prefersDark ? "dark" : "light");
  }
  syncThemeIcons();

  for (const btn of document.querySelectorAll("[data-theme-toggle]")) {
    btn.addEventListener("click", toggleTheme);
  }
}
