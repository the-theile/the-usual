// Dates are handled as 'YYYY-MM-DD' strings in the bartender's own timezone.
// A "bar day" runs 5am → 5am, matching the server (private.bar_day).

const BAR_DAY_OFFSET_MS = 5 * 60 * 60 * 1000;

export function barDay(timezone, now = Date.now()) {
  return ymdInZone(new Date(now - BAR_DAY_OFFSET_MS), timezone);
}

function ymdInZone(date, timeZone) {
  try {
    return new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(date);
  } catch {
    return new Intl.DateTimeFormat('en-CA', { year: 'numeric', month: '2-digit', day: '2-digit' }).format(date);
  }
}

export function addDays(ymd, n) {
  const d = new Date(`${ymd}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

/** ISO weekday 1 (Mon) … 7 (Sun) */
export function isoWeekday(ymd) {
  const d = new Date(`${ymd}T12:00:00Z`).getUTCDay();
  return d === 0 ? 7 : d;
}

export function dayLabel(ymd, today) {
  if (ymd === today) return 'Tonight';
  if (ymd === addDays(today, 1)) return 'Tomorrow';
  return new Date(`${ymd}T12:00:00Z`).toLocaleDateString(undefined, {
    timeZone: 'UTC', weekday: 'long', month: 'short', day: 'numeric',
  });
}

/** '18:00:00' → '6pm', '18:30' → '6:30pm', null → 'close' */
export function fmtTime(t) {
  if (!t) return 'close';
  const [hh, mm] = t.split(':').map(Number);
  const suffix = hh >= 12 ? 'pm' : 'am';
  const h12 = hh % 12 === 0 ? 12 : hh % 12;
  if (hh === 0 && mm === 0) return 'midnight';
  if (hh === 12 && mm === 0) return 'noon';
  return mm ? `${h12}:${String(mm).padStart(2, '0')}${suffix}` : `${h12}${suffix}`;
}

export function fmtShift(start, end) {
  return `${fmtTime(start)} – ${fmtTime(end)}`;
}

export const WEEKDAYS = [
  { n: 1, short: 'Mon', long: 'Monday' },
  { n: 2, short: 'Tue', long: 'Tuesday' },
  { n: 3, short: 'Wed', long: 'Wednesday' },
  { n: 4, short: 'Thu', long: 'Thursday' },
  { n: 5, short: 'Fri', long: 'Friday' },
  { n: 6, short: 'Sat', long: 'Saturday' },
  { n: 7, short: 'Sun', long: 'Sunday' },
];

export function fmtWeekdays(days) {
  const sorted = [...days].sort((a, b) => a - b);
  if (sorted.length === 7) return 'Every day';
  return 'Every ' + sorted.map((n) => WEEKDAYS[n - 1].short).join(', ');
}

export function timeAgo(iso) {
  const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  if (s < 86400) { const h = Math.floor(s / 3600); return `${h} hour${h > 1 ? 's' : ''} ago`; }
  const d = Math.floor(s / 86400);
  if (d < 7) return `${d} day${d > 1 ? 's' : ''} ago`;
  return new Date(iso).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

export function fmtDate(iso) {
  return new Date(iso).toLocaleDateString(undefined, { month: 'long', day: 'numeric', year: 'numeric' });
}

export function localTimezone() {
  try { return Intl.DateTimeFormat().resolvedOptions().timeZone || 'America/Los_Angeles'; }
  catch { return 'America/Los_Angeles'; }
}

// ===== Birthdays (month + day, no year) =====

export const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December'];

export function daysInMonth(m) {
  return m === 2 ? 29 : [4, 6, 9, 11].includes(m) ? 30 : 31;
}

/** 3, 14 → 'March 14'; null → '' */
export function fmtBirthday(m, d) {
  return m && d ? `${MONTHS[m - 1]} ${d}` : '';
}

/**
 * People whose birthday falls within `days` days from `today` ('YYYY-MM-DD').
 * Feb 29 birthdays show on Feb 28 in non-leap years.
 * @returns {{ person: object, ymd: string }[]} soonest first
 */
export function upcomingBirthdays(people, today, days = 7) {
  const out = [];
  for (let k = 0; k < days; k++) {
    const ymd = addDays(today, k);
    const [y, m, d] = ymd.split('-').map(Number);
    const leap = (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
    for (const p of people) {
      if (p.birthday_month !== m) continue;
      if (p.birthday_day === d || (!leap && m === 2 && d === 28 && p.birthday_day === 29)) out.push({ person: p, ymd });
    }
  }
  return out;
}
