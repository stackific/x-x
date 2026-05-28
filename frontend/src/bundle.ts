import "beercss/dist/cdn/beer.min.css";
import "@fontsource-variable/geist";
import "material-dynamic-colors";
import "./styles/app.scss";

import { essay } from "./pages/essay";
import { home } from "./pages/home";
import { scope } from "./pages/scope";
import { scopes } from "./pages/scopes";
import { search } from "./pages/search";
import { system } from "./pages/system";
import { systems } from "./pages/systems";
import { syncActiveNav } from "./shared/nav";
import { initSidebar } from "./shared/sidebar";
import { initTheme } from "./shared/theme";

const pages: Record<string, () => void | Promise<void>> = {
  home,
  search,
  systems,
  system,
  scopes,
  scope,
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
