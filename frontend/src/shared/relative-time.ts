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
export function relativeTime(iso: string, now: number = Date.now()): string {
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
