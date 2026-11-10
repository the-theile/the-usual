// #/sample — public, read-only example of a bartender's page, for visitors who haven't signed in.
// Mirrors the layout and classes of views/regular/bartender.js. Everything here is hard-coded
// sample data: no Supabase calls, no reporting, no analytics. Every action leads to sign-in.
import { h, screen, backLink } from '../lib/dom.js';
import { navigate } from '../router.js';
import { barDay, addDays, dayLabel, fmtShift, localTimezone, timeAgo } from '../lib/time.js';
import { toast } from '../lib/toast.js';
import { avatar } from './regular/home.js';
import { REACTIONS } from './responses.js';

// ===== Sample data (fictional) =====
const NAME = 'Sam Sample';
const BIO = 'Sample bartender. Classic cocktails, good playlists, and the best seat at the bar.';
const BARS = [
  { name: 'The Sample Room', area: 'Downtown, Anytown' },
  { name: 'Lantern Lounge', area: 'Old Harbor, Anytown' },
];
// Day offsets from today; times use the same 'HH:MM' shape as get_schedule.
const SHIFTS = [
  { day: 0, bar_name: 'The Sample Room', start_time: '18:00', end_time: '02:00', note: 'Tasting the new fall menu tonight.' },
  { day: 1, bar_name: 'Lantern Lounge', start_time: '17:00', end_time: '23:00' },
  { day: 3, bar_name: 'The Sample Room', start_time: '19:00', end_time: null },
  { day: 5, bar_name: 'Lantern Lounge', start_time: '20:00', end_time: '02:00' },
];
const HOUR = 3600000;
const POSTS = [
  { hoursAgo: 2, body: 'Behind the bar at The Sample Room from 6 tonight. First pour of the new spiced pear sour is on me if you say “the usual.”',
    counts: { cheers: 12, fire: 5, love: 3 } },
  { hoursAgo: 50, body: 'Swapped my Thursday — find me at Lantern Lounge this week instead.',
    counts: { cheers: 4, eyes: 2 } },
];

// ===== Sign-in CTA =====
// Sign-in itself is unchanged; the short line shows as a toast on the way there.
function toSignin(line) {
  toast(line);
  navigate('/signin');
}

function signinLink(label, line, cls) {
  return h('a', { class: cls, href: '#/signin', onClick: (e) => { e.preventDefault(); toSignin(line); } }, label);
}

// Same markup as postCard + regularPostFooter, minus the backend (report, live reactions, thread link).
function samplePost(p) {
  return h('article', { class: 'card post' },
    h('div', { class: 'post-head' },
      avatar(null, NAME, 'avatar-sm'),
      h('span', {}, h('strong', {}, NAME), h('span', { class: 'help block' }, timeAgo(new Date(Date.now() - p.hoursAgo * HOUR).toISOString())))),
    h('p', { class: 'post-body' }, p.body),
    h('div', { class: 'post-responses' },
      h('div', { class: 'reactions', role: 'group', 'aria-label': 'Reactions (sign in to react)' },
        REACTIONS.filter((r) => p.counts[r.key]).map((r) => h('button', {
          type: 'button', class: 'reaction',
          'aria-label': `${r.label}, ${p.counts[r.key]}. Sign in to react`,
          onClick: () => toSignin('Sign in to react to updates.'),
        }, h('span', { 'aria-hidden': 'true' }, r.emoji), h('span', { class: 'reaction-n' }, p.counts[r.key])))),
      signinLink([h('span', { 'aria-hidden': 'true' }, '💬'), `Reply to ${NAME}`, h('span', { class: 'chev', 'aria-hidden': 'true' }, '›')],
        'Sign in to reply to bartenders.', 'reply-link'),
    ),
  );
}

export async function sampleView() {
  const today = barDay(localTimezone());
  const shifts = SHIFTS.map((s) => ({ ...s, occurrence_date: addDays(today, s.day) }));
  const tonight = shifts.filter((s) => s.occurrence_date === today);
  const later = shifts.filter((s) => s.occurrence_date !== today);
  const shiftNote = (s) => (s.note ? h('span', { class: 'help block' }, s.note) : null);

  return screen(
    backLink('#/welcome'),
    h('p', { class: 'card note' },
      h('strong', {}, 'Sample profile — this is an example. '),
      'Sam isn’t a real bartender. This is how a bartender’s page looks to their regulars.'),
    h('header', { class: 'profile-head' },
      avatar(null, NAME, 'avatar-xl'),
      h('h1', {}, NAME),
      h('p', { class: 'lead' }, BIO),
    ),

    h('section', { class: 'card tonight', 'aria-labelledby': 'tonight-h' },
      h('p', { class: 'eyebrow', id: 'tonight-h' }, 'Tonight'),
      tonight.map((s) => h('p', { class: 'shift-line' }, h('strong', {}, s.bar_name), ' · ', fmtShift(s.start_time, s.end_time), shiftNote(s))),
    ),

    h('section', { 'aria-labelledby': 'coming-h' },
      h('h2', { id: 'coming-h' }, 'Coming up'),
      h('ul', { class: 'plain-list schedule-list' }, later.map((s) => h('li', {},
        h('span', { class: 'day-label' }, dayLabel(s.occurrence_date, today, { short: true })),
        h('span', {}, h('strong', { class: 'block' }, s.bar_name), h('span', { class: 'shift-time' }, fmtShift(s.start_time, s.end_time)), shiftNote(s))))),
    ),

    h('section', { 'aria-labelledby': 'bars-h' },
      h('h2', { id: 'bars-h' }, `Where to find ${NAME}`),
      h('ul', { class: 'plain-list' }, BARS.map((x) => h('li', { class: 'bar-item' },
        h('strong', {}, x.name), h('span', { class: 'help' }, ` · ${x.area}`)))),
    ),

    h('section', { 'aria-labelledby': 'posts-h' },
      h('h2', { id: 'posts-h' }, 'Updates'),
      POSTS.map(samplePost),
    ),

    h('div', { class: 'card note stack' },
      h('p', {}, 'Regulars see all of their bartender’s updates, and can react and reply. Sign in to follow bartenders.'),
      signinLink('Sign in to follow', 'Sign in to follow bartenders.', 'btn btn-primary')),
  );
}
