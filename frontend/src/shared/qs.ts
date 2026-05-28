export function qs(key: string, fallback = ""): string {
  return new URLSearchParams(location.search).get(key) ?? fallback;
}
