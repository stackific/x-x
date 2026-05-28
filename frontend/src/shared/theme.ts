import ui from "beercss";
import { THEME } from "../constants";

const { seedColor: SEED_COLOR, storageKey: THEME_KEY } = THEME;

function syncThemeIcons(): void {
  const isDark = document.body.classList.contains("dark");
  const icon = isDark ? "light_mode" : "dark_mode";
  for (const el of document.querySelectorAll("[data-theme-toggle] i")) {
    el.textContent = icon;
  }
}

function toggleTheme(): void {
  const isDark = document.body.classList.contains("dark");
  const next = isDark ? "light" : "dark";
  ui("mode", next);
  localStorage.setItem(THEME_KEY, next);
  syncThemeIcons();
}

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
