import { existsSync, readdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig, type PluginOption } from "vite";
import handlebars from "vite-plugin-handlebars";

const root = dirname(fileURLToPath(import.meta.url));

const pages = ["index", "search", "systems", "minibooks", "essay", "404"] as const;

// Rename the deduplicated entry chunk (Vite/Rollup emits `bundleN.js` when
// multiple HTML entries all request the same `bundle.js` name) back to
// `bundle.js`, and rewrite HTML references. Build-only.
const renameBundle = (): PluginOption => ({
  name: "stax-rename-bundle",
  apply: "build",
  closeBundle() {
    const dist = resolve(root, "dist");
    if (!existsSync(dist)) return;
    const files = readdirSync(dist);
    const target = files.find((f) => /^bundle\d+\.js$/.test(f));
    if (!target) return;
    const final = "bundle.js";
    renameSync(resolve(dist, target), resolve(dist, final));
    for (const f of files) {
      if (!f.endsWith(".html")) continue;
      const p = resolve(dist, f);
      writeFileSync(p, readFileSync(p, "utf8").split(target).join(final));
    }
  },
});

// Rewrite extensionless URLs (`/systems`) to their `.html` file during dev so
// the in-browser experience matches production (where static hosts serve
// `systems.html` for `/systems` natively). Skips files, Vite internals, and root.
const htmlFallback = (): PluginOption => ({
  name: "stax-html-fallback",
  configureServer(server) {
    server.middlewares.use((req, _res, next) => {
      const url = req.url ?? "";
      if (
        url === "/" ||
        url.includes(".") ||
        url.startsWith("/@") ||
        url.startsWith("/src/") ||
        url.startsWith("/node_modules/")
      ) {
        return next();
      }
      const [path, query] = url.split("?", 2);
      const candidate = resolve(root, `${path.slice(1)}.html`);
      if (existsSync(candidate)) {
        req.url = `${path}.html${query ? `?${query}` : ""}`;
      }
      next();
    });
  },
});

export default defineConfig({
  appType: "mpa",
  plugins: [
    htmlFallback(),
    handlebars({
      partialDirectory: resolve(root, "partials"),
    }),
    renameBundle(),
  ],
  server: {
    proxy: {
      "/api": "http://localhost:7829",
    },
  },
  build: {
    target: "es2022",
    minify: "terser",
    terserOptions: {
      compress: {
        passes: 3,
        drop_console: true,
        drop_debugger: true,
        ecma: 2020,
      },
      mangle: true,
      format: { comments: false },
    },
    cssCodeSplit: false,
    cssMinify: true,
    rollupOptions: {
      // bundle.ts has no exports — let Rollup merge entry chunks into one.
      preserveEntrySignatures: false,
      input: Object.fromEntries(pages.map((p) => [p, resolve(root, `${p}.html`)])),
      output: {
        entryFileNames: "bundle.js",
        chunkFileNames: "bundle.js",
        assetFileNames: (info) => {
          if (info.name?.endsWith(".css")) return "bundle.css";
          return "assets/[name][extname]";
        },
      },
    },
  },
});
