import "beercss/dist/cdn/beer.min.css";
import "@fontsource-variable/geist";
import "material-dynamic-colors";
import "./styles/app.scss";
import ui from "beercss";
import { THEME } from "./constants";
import { initRouter } from "./router";

const { seedColor: SEED_COLOR, storageKey: THEME_KEY, sidebarKey: SIDEBAR_KEY } = THEME;

function initTheme() {
  ui("theme", SEED_COLOR);
  const saved = localStorage.getItem(THEME_KEY);
  if (saved === "light" || saved === "dark") {
    ui("mode", saved);
  } else {
    const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
    ui("mode", prefersDark ? "dark" : "light");
  }
  syncThemeIcons();
}

function toggleTheme() {
  const isDark = document.body.classList.contains("dark");
  const next = isDark ? "light" : "dark";
  ui("mode", next);
  localStorage.setItem(THEME_KEY, next);
  syncThemeIcons();
}

function syncThemeIcons() {
  const isDark = document.body.classList.contains("dark");
  const icon = isDark ? "light_mode" : "dark_mode";
  document.querySelectorAll("[data-theme-toggle] i").forEach((el) => {
    el.textContent = icon;
  });
}

function toggleSidebar() {
  const nav = document.querySelector("nav.left.l");
  if (!nav) return;
  const expanded = nav.classList.toggle("max");
  const btn = nav.querySelector("[aria-label='Toggle sidebar']");
  if (btn) {
    btn.setAttribute("aria-expanded", String(expanded));
    const icon = btn.querySelector("i");
    if (icon) icon.textContent = expanded ? "menu_open" : "menu";
  }
  localStorage.setItem(SIDEBAR_KEY, expanded ? "expanded" : "collapsed");
}

function restoreSidebar() {
  const saved = localStorage.getItem(SIDEBAR_KEY);
  if (saved !== "expanded") return;
  const nav = document.querySelector("nav.left.l");
  if (!nav) return;
  nav.classList.add("max");
  const btn = nav.querySelector("[aria-label='Toggle sidebar']");
  if (!btn) return;
  btn.setAttribute("aria-expanded", "true");
  const icon = btn.querySelector("i");
  if (icon) icon.textContent = "menu_open";
}

function start() {
  document.querySelectorAll("[data-theme-toggle]").forEach((btn) => {
    btn.addEventListener("click", toggleTheme);
  });
  document.getElementById("sidebar-toggle")?.addEventListener("click", toggleSidebar);

  initTheme();
  restoreSidebar();
  initRouter();
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", start);
} else {
  start();
}
