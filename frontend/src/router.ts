import { categories } from "./pages/categories";
import { essay } from "./pages/essay";
import { home } from "./pages/home";
import { minibooks } from "./pages/minibooks";
import { notFound } from "./pages/not-found";
import { search } from "./pages/search";

// Page render functions may optionally accept URLSearchParams when they want
// to react to query strings. TypeScript widens () => string to fit this slot,
// so pages that don't care keep their zero-arg signature.
type Renderer = (params: URLSearchParams) => string | Promise<string>;

type Route = {
  test: (path: string) => boolean;
  render: Renderer;
  active: string;
};

const routes: Route[] = [
  { test: (p) => p === "/", render: home, active: "home" },
  { test: (p) => p === "/search", render: search, active: "search" },
  {
    test: (p) => p === "/categories" || p.startsWith("/categories/"),
    render: categories,
    active: "categories",
  },
  {
    test: (p) => p === "/minibooks" || p.startsWith("/minibooks/"),
    render: minibooks,
    active: "minibooks",
  },
  { test: (p) => p.startsWith("/essays/"), render: essay, active: "home" },
];

function resolve(path: string): { render: Renderer; active: string } {
  for (const r of routes) if (r.test(path)) return r;
  return { render: notFound, active: "" };
}

function syncNavActive(active: string): void {
  document.querySelectorAll<HTMLAnchorElement>("[data-nav-link]").forEach((el) => {
    const key = el.dataset.activeKey ?? "";
    el.classList.toggle("active", key !== "" && key === active);
  });
}

async function render(url: URL): Promise<void> {
  const route = resolve(url.pathname);
  const main = document.getElementById("main-content");
  if (main) main.innerHTML = await route.render(url.searchParams);
  syncNavActive(route.active);
  window.scrollTo(0, 0);
}

function shouldIntercept(a: HTMLAnchorElement, e: MouseEvent): boolean {
  if (a.target && a.target !== "_self") return false;
  if (a.hasAttribute("download")) return false;
  if (a.getAttribute("rel")?.includes("external")) return false;
  if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return false;
  const href = a.getAttribute("href");
  if (!href) return false;
  if (!href.startsWith("/")) return false;
  return true;
}

export function initRouter(): void {
  document.addEventListener("click", (e) => {
    const target = e.target as Element | null;
    const a = target?.closest("a") as HTMLAnchorElement | null;
    if (!a) return;
    if (!shouldIntercept(a, e)) return;
    e.preventDefault();
    const href = a.getAttribute("href");
    if (!href) return;
    const url = new URL(href, window.location.origin);
    if (url.pathname !== window.location.pathname || url.search !== window.location.search) {
      window.history.pushState({}, "", url.pathname + url.search);
    }
    void render(url);
  });

  window.addEventListener("popstate", () => {
    void render(new URL(window.location.href));
  });

  void render(new URL(window.location.href));
}
