import { defineConfig } from "vite";

// Single-bundle, heavily optimized production output:
//   dist/index.html
//   dist/bundle.js   (Terser-minified, modern target, multiple compress passes)
//   dist/bundle.css  (single sheet, minified)
//   dist/assets/*    (woff2 fonts referenced from CSS)
//
// Tree-shaking is on by default (Rollup recommended preset). Side-effect CSS
// imports (beercss CSS, @fontsource-variable/geist, app.scss) are preserved by
// Vite's CSS plugin regardless of preset.
export default defineConfig({
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
