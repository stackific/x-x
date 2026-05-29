// Typed fetch wrapper used by every page that talks to the Go backend's
// `/api/*` JSON surface. Pages use it like:
//
//   const data = await api<SystemsResponse>("/api/systems");
//
// The generic `T` is the response shape as declared in the calling
// page's `type ...` alias — kept on the page side (not centralized
// here) because each page knows the exact subset it consumes and
// pulling every shape into one shared types file would tightly couple
// the pages we want to keep independent.
//
// Failure model:
//   - Non-2xx responses throw an Error carrying status + path. Pages
//     wrap the call in try/catch and render an error-template node
//     so a 404 / 500 surfaces in the UI rather than silently filling
//     an empty list.
//   - Network errors propagate the underlying fetch rejection.
//
// `path` — typically a same-origin `/api/...` URL; Vite's dev server
//          proxies these to `http://localhost:7829` per
//          `vite.config.ts`'s `server.proxy` block, and the production
//          binary serves both `/api/*` and the static UI from the same
//          loopback origin so no CORS dance is needed either way.
// `init` — optional fetch init (method, headers, body). Most callers
//          pass nothing and get a GET.
export async function api<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(path, init);
  if (!res.ok) {
    throw new Error(`${res.status} ${res.statusText} — ${path}`);
  }
  return (await res.json()) as T;
}
