import "beercss/dist/cdn/beer.min.css";
import "@fontsource-variable/geist";
import "material-dynamic-colors";
import "./styles/app.scss";

import { essay } from "./pages/essay";
import { home } from "./pages/home";
import { minibooks } from "./pages/minibooks";
import { search } from "./pages/search";
import { systems } from "./pages/systems";
import { syncActiveNav } from "./shared/nav";
import { initSidebar } from "./shared/sidebar";
import { initTheme } from "./shared/theme";

const pages: Record<string, () => void | Promise<void>> = {
  home,
  search,
  systems,
  minibooks,
  essay,
};

function start(): void {
  initTheme();
  initSidebar();
  syncActiveNav();

  const name = document.body.dataset.page ?? "";
  const init = pages[name];
  if (init) {
    Promise.resolve(init()).catch((err: unknown) => {
      console.error(`[bundle] page "${name}" init failed:`, err);
    });
  }
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", start);
} else {
  start();
}
