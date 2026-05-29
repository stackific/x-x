// Query-string reader for the page-init dispatcher. Pages that key off
// a URL parameter (`/work-item?id=`, `/system?id=`, `/search?q=`) share this
// one helper rather than each constructing their own URLSearchParams —
// keeps the parameter-name convention discoverable and the empty-case
// behavior uniform (missing key → fallback, never `null`/`undefined`).
//
// `key`      — the query-string parameter name.
// `fallback` — returned when the parameter is absent. Defaults to the
//              empty string so callers can branch on `if (!value)`
//              without a separate undefined check.
export function qs(key: string, fallback = ""): string {
  return new URLSearchParams(location.search).get(key) ?? fallback;
}
