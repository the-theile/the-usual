import { h, screen } from '../../lib/dom.js';
import { supabase } from '../../supabase.js';
import { me, setMode } from '../../state.js';
import { navigate } from '../../router.js';
import { fmtShift, timeAgo } from '../../lib/time.js';
import { photoUrls } from '../../lib/images.js';
import { signOut } from '../bartender/home.js';

export function avatar(url, name, size = '') {
  return url
    ? h('img', { class: `avatar ${size}`, src: url, alt: '' })
    : h('span', { class: `avatar avatar-initial ${size}`, 'aria-hidden': 'true' }, (name || '?').trim().charAt(0).toUpperCase());
}

export function postCard(p, { name, avatarUrl, photo, href }) {
  return h('article', { class: 'card post' },
    h('a', { class: 'post-head', href },
      avatar(avatarUrl, name, 'avatar-sm'),
      h('span', {}, h('strong', {}, name), h('span', { class: 'help block' }, timeAgo(p.created_at)))),
    photo ? h('img', { class: 'post-photo', src: photo, alt: `Photo from ${name}`, loading: 'lazy' }) : null,
    p.body ? h('p', { class: 'post-body' }, p.body) : null,
  );
}

export async function regularHomeView() {
  const { data: rows, error } = await supabase.rpc('whos_working_tonight');
  if (error) throw error;

  // One entry per bartender, possibly several shifts tonight.
  const byB = new Map();
  for (const r of rows) {
    if (!byB.has(r.bartender_id)) byB.set(r.bartender_id, { ...r, shifts: [] });
    if (r.bar_name) byB.get(r.bartender_id).shifts.push(r);
  }
  const bartenders = [...byB.values()];
  const ids = bartenders.map((b) => b.bartender_id);

  const { data: posts } = ids.length
    ? await supabase.from('posts').select('id, bartender_id, body, photo_path, created_at')
        .in('bartender_id', ids).order('created_at', { ascending: false }).limit(30)
    : { data: [] };

  const [avatars, photos] = await Promise.all([
    photoUrls('avatars', bartenders.map((b) => b.photo_path)),
    photoUrls('post-photos', (posts || []).map((p) => p.photo_path)),
  ]);

  const working = bartenders.filter((b) => b.shifts.length);
  const off = bartenders.filter((b) => !b.shifts.length);

  const card = (b) => h('a', { class: `card bartender-card ${b.shifts.length ? 'on' : 'off'}`, href: `#/b/${b.public_id}` },
    avatar(avatars[b.photo_path], b.display_name),
    h('span', { class: 'bc-text' },
      h('strong', { class: 'bc-name' }, b.display_name),
      b.shifts.length
        ? b.shifts.map((s) => h('span', { class: 'bc-shift' },
            h('span', { class: 'bc-bar' }, s.bar_name), s.bar_area ? h('span', { class: 'help' }, ` · ${s.bar_area}`) : null,
            h('span', { class: 'block' }, fmtShift(s.start_time, s.end_time)),
            s.note ? h('span', { class: 'help block' }, s.note) : null))
        : h('span', { class: 'bc-off' }, 'Off tonight')),
    h('span', { class: 'chev', 'aria-hidden': 'true' }, '›'));

  const nameOf = Object.fromEntries(bartenders.map((b) => [b.bartender_id, b]));

  return screen(
    h('header', { class: 'topbar' },
      h('p', { class: 'brand-small' }, 'The Usual'),
      h('h1', {}, 'Who’s working tonight'),
    ),

    bartenders.length === 0
      ? h('div', { class: 'card note stack' },
          h('p', { class: 'lead' }, 'You’re not following anyone yet.'),
          h('p', {}, 'Ask your bartender for their code, or scan their QR code with your phone’s camera.'),
          h('a', { class: 'btn btn-primary btn-xl', href: '#/code', 'data-autofocus': '' }, 'I have a code'))
      : h('div', { class: 'stack-tight' }, working.map(card), off.map(card)),

    bartenders.length ? h('a', { class: 'btn btn-secondary', href: '#/code' }, '＋ Add a bartender') : null,

    bartenders.length
      ? h('section', { 'aria-labelledby': 'latest' },
          h('h2', { id: 'latest' }, 'Latest updates'),
          (posts || []).length
            ? posts.map((p) => {
                const b = nameOf[p.bartender_id];
                return postCard(p, { name: b.display_name, avatarUrl: avatars[b.photo_path], photo: photos[p.photo_path], href: `#/b/${b.public_id}` });
              })
            : h('p', { class: 'muted' }, 'No updates yet.'))
      : null,

    h('nav', { class: 'menu', 'aria-label': 'More' },
      me.bartender
        ? h('button', { type: 'button', class: 'menu-row', onClick: () => { setMode('bartender'); navigate('/'); } },
            'Go to my bartender screen', h('span', { 'aria-hidden': 'true' }, '›'))
        : h('a', { class: 'menu-row', href: '#/become-bartender' }, 'Are you a bartender? Set up your page', h('span', { 'aria-hidden': 'true' }, '›')),
      h('button', { type: 'button', class: 'menu-row', onClick: signOut }, 'Sign out', h('span', { 'aria-hidden': 'true' }, '›')),
    ),
  );
}
