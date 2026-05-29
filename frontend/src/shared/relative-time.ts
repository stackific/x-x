import { $, tpl } from "./dom";

// Format a timestamp as a coarse human-readable relative string.
//
// Examples:
//   "just now"
//   "5 minutes ago"
//   "3 hours ago"
//   "8 months 12 days ago"
//   "2 years 3 months ago"
//
// Calendar math (years/months/days) is computed from real Date fields so
// "1 month ago" is the same calendar day in the previous month, not
// exactly 30 * 86400 seconds. Days are only emitted when years === 0 —
// "2 years 3 months 17 days ago" is noisier than useful at that range.
function relativeTime(iso: string, now: number = Date.now()): string {
  const then = new Date(iso).getTime();
  if (Number.isNaN(then)) return iso;
  const diffMs = Math.max(0, now - then);

  const sec = Math.floor(diffMs / 1000);
  if (sec < 60) return "just now";

  const min = Math.floor(sec / 60);
  if (min < 60) return `${min} ${pluralize("minute", min)} ago`;

  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr} ${pluralize("hour", hr)} ago`;

  const past = new Date(then);
  const present = new Date(now);
  let years = present.getUTCFullYear() - past.getUTCFullYear();
  let months = present.getUTCMonth() - past.getUTCMonth();
  let days = present.getUTCDate() - past.getUTCDate();

  if (days < 0) {
    months -= 1;
    // Day count of the month immediately before `present`.
    const prevMonthDays = new Date(
      Date.UTC(present.getUTCFullYear(), present.getUTCMonth(), 0),
    ).getUTCDate();
    days += prevMonthDays;
  }
  if (months < 0) {
    years -= 1;
    months += 12;
  }

  const parts: string[] = [];
  if (years > 0) parts.push(`${years} ${pluralize("year", years)}`);
  if (months > 0) parts.push(`${months} ${pluralize("month", months)}`);
  if (years === 0 && days > 0) parts.push(`${days} ${pluralize("day", days)}`);
  if (parts.length === 0) return "today";
  return `${parts.join(" ")} ago`;
}

function pluralize(noun: string, n: number): string {
  return n === 1 ? noun : `${noun}s`;
}

// applyRelativeTime stamps the fuzzy `relativeTime(iso)` string into
// `el` and adds a BeerCSS tooltip with the unambiguous absolute
// timestamp underneath. Wraps the two-step (text + cloned template)
// pattern in one call so every list/detail view renders its created
// dates uniformly — same fuzzy primary, same absolute on hover, same
// position class, no per-page DOM construction.
//
// Steps:
//   1. textContent replaces prior children (a stale tooltip from a
//      previous render goes with them).
//   2. tooltip-anchor establishes positioning context so the
//      absolute-positioned .tooltip lays out relative to `el` rather
//      than the body.
//   3. tpl-tooltip is cloned from layout.html's shared template and
//      filled with the formatted absolute timestamp.
//
// Falls back gracefully on an unparseable iso: relativeTime echoes the
// raw string, and absoluteTimestamp returns the same. Better to show
// the raw value than a broken/empty tooltip.
export function applyRelativeTime(el: HTMLElement, iso: string): void {
  el.textContent = relativeTime(iso);
  el.classList.add("tooltip-anchor");
  const node = tpl("tpl-tooltip");
  $('[data-slot="content"]', node).textContent = absoluteTimestamp(iso);
  el.appendChild(node);
}

// absoluteTimestamp formats an ISO string as a locale-readable date +
// time with a timezone abbreviation so the tooltip is unambiguous
// regardless of the user's locale. Falls back to the raw string when
// the input doesn't parse — the relativeTime primary will also echo
// the raw value, so the row stays self-consistent.
//
// Uses individual field options (year/month/day/hour/minute) rather
// than the dateStyle/timeStyle shorthand because Intl.DateTimeFormat
// throws RangeError("Invalid option : option") at runtime when those
// shorthands are combined with timeZoneName — the spec forbids
// mixing the two families. TypeScript can't catch this; only the
// runtime can. So we spell out the fields.
function absoluteTimestamp(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleString(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
    timeZoneName: "short",
  });
}
