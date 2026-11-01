// #/b/:public_id — a bartender's page as a regular (or public-schedule viewer) sees it.
import { h, screen, backLink, actionButton, confirmDialog } from '../../lib/dom.js';
import { supabase } from '../../supabase.js';
import { me, uid, setReturnTo } from '../../state.js';
import { navigate } from '../../router.js';
import { barDay, addDays, dayLabel, fmtShift } from '../../lib/time.js';
import { photoUrls } from '../../lib/images.js';
import { toast, oops } from '../../lib/toast.js';
import { avatar, postCard } from './home.js';
import { loadRegularResponses, regularPostFooter } from '../responses.js';

export async function bartenderPageView({ params }) {
  // The route is public so signed-out visitors get a preview of public pages.
  if (!me.session) return signedOutPageView(params.pid);
  if (!me.profile) {
    setReturnTo(`/b/${params.pid}`);
    navigate('/onboarding', { replace: true });
    return null;
  }

  // RLS returns nothing if this person can't see the bartender (not connected and
  // not public, or blocked). Same message either way.
  const { data: b } = await supabase.from('bartenders')
    .select('id, public_id, bio, photo_path, timezone, schedule_visibility, profiles!bartenders_id_fkey(display_name)')
    .eq('public_id', params.pid).maybeSingle();
  if (!b) {
    return screen(backLink('#/'), h('h1', {}, 'Page not found'),
      h('p', { class: 'lead' }, 'This page isn’t available. If you know this bartender, ask them for today’s code.'),
      h('a', { class: 'btn btn-primary', href: '#/code' }, 'I have a code'));
  }
  const name = b.profiles?.display_name || 'Bartender';
  const isMe = b.id === uid();
  const today = barDay(b.timezone);

  const [barsRes, schedRes, postsRes, connRes] = await Promise.all([
    supabase.from('bars').select('id, name, area').eq('bartender_id', b.id).order('sort'),
    supabase.rpc('get_schedule', { p_bartenders: [b.id], p_from: today, p_to: addDays(today, 13) }),
    supabase.from('posts').select('id, bartender_id, body, photo_path, created_at, visibility').eq('bartender_id', b.id)
      .order('created_at', { ascending: false }).limit(20),
    supabase.from('connections').select('bartender_id').eq('bartender_id', b.id).eq('regular_id', uid()).maybeSingle(),
  ]);
  const shifts = (schedRes.data || []).filter((s) => !s.cancelled);
  const posts = postsRes.data || [];
  const connected = !!connRes.data;
  const [avatars, photos, responses] = await Promise.all([
    photoUrls('avatars', [b.photo_path]),
    photoUrls('post-photos', posts.map((p) => p.photo_path)),
    isMe ? null : loadRegularResponses(posts.map((p) => p.id)),
  ]);
  const avatarUrl = avatars[b.photo_path];

  const tonight = shifts.filter((s) => s.occurrence_date === today);
  const later = shifts.filter((s) => s.occurrence_date !== today);

  return screen(
    backLink('#/'),
    isMe ? h('p', { class: 'card note' }, 'This is how your page looks to your regulars.') : null,
    h('header', { class: 'profile-head' },
      avatar(avatarUrl, name, 'avatar-xl'),
      h('h1', {}, name),
      b.bio ? h('p', { class: 'lead' }, b.bio) : null,
    ),

    h('section', { class: 'card tonight', 'aria-labelledby': 'tonight-h' },
      h('p', { class: 'eyebrow', id: 'tonight-h' }, 'Tonight'),
      tonight.length
        ? tonight.map((s) => h('p', { class: 'shift-line' }, h('strong', {}, s.bar_name), ' · ', fmtShift(s.start_time, s.end_time),
            s.note ? h('span', { class: 'help block' }, s.note) : null))
        : h('p', { class: 'shift-line muted' }, 'Off tonight'),
    ),

    h('section', { 'aria-labelledby': 'coming-h' },
      h('h2', { id: 'coming-h' }, 'Coming up'),
      later.length
        ? h('ul', { class: 'plain-list schedule-list' }, later.map((s) => h('li', {},
            h('span', { class: 'day-label' }, dayLabel(s.occurrence_date, today)),
            h('span', {}, h('strong', {}, s.bar_name), ' · ', fmtShift(s.start_time, s.end_time),
              s.note ? h('span', { class: 'help block' }, s.note) : null))))
        : h('p', { class: 'muted' }, 'No shifts posted for the next two weeks.'),
    ),

    (barsRes.data || []).length
      ? h('section', { 'aria-labelledby': 'bars-h' },
          h('h2', { id: 'bars-h' }, `Where ${isMe ? 'I work' : 'to find ' + name}`),
          h('ul', { class: 'plain-list' }, barsRes.data.map((x) => h('li', { class: 'bar-item' },
            h('strong', {}, x.name), x.area ? h('span', { class: 'help' }, ` · ${x.area}`) : null))))
      : null,

    // Regulars see every update; anyone else only the ones marked Public (RLS).
    connected || isMe || posts.length
      ? h('section', { 'aria-labelledby': 'posts-h' },
          h('h2', { id: 'posts-h' }, 'Updates'),
          posts.length
            ? posts.map((p) => postCard(p, {
                name, avatarUrl, photo: photos[p.photo_path], href: `#/b/${b.public_id}`,
                footer: responses ? regularPostFooter(p, name, { counts: responses.counts[p.id], thread: responses.threads[p.id], readOnly: !connected }) : null,
              }))
            : h('p', { class: 'muted' }, 'No updates yet.'))
      : null,
    connected || isMe
      ? null
      : h('div', { class: 'card note stack' },
          h('p', {}, posts.length
            ? `Regulars see all of ${name}’s updates, and can react and reply. Ask ${name} for today’s code to follow.`
            : `Updates from ${name} are for regulars. Ask ${name} for today’s code to follow.`),
          h('a', { class: 'btn btn-primary', href: '#/code' }, 'I have a code')),

    connected
      ? actionButton(`Stop following ${name}`, async () => {
          const ok = await confirmDialog({
            title: `Stop following ${name}?`,
            body: `You’d need a new code from ${name} to follow again.`,
            confirmText: 'Stop following', cancelText: 'Keep following', danger: true,
          });
          if (!ok) return;
          const { error } = await supabase.from('connections').delete().eq('bartender_id', b.id).eq('regular_id', uid());
          if (error) return oops(error);
          toast(`You no longer follow ${name}`);
          navigate('/', { replace: true });
        }, { class: 'btn btn-ghost' })
      : null,
  );
}

// Signed out: read-only preview of a public page (schedule + Public updates).
// Everything comes from one function that only answers for public pages.
async function signedOutPageView(pid) {
  const { data: pg, error } = await supabase.rpc('public_page', { p_public_id: pid });
  if (error) throw error;
  const signIn = (label, cls = 'btn btn-primary') => h('a', {
    class: cls, href: '#/signin', onClick: () => setReturnTo(`/b/${pid}`),
  }, label);
  if (!pg) {
    return screen(h('h1', {}, 'Page not found'),
      h('p', { class: 'lead' }, 'This page isn’t available. If you know this bartender, sign in and ask them for today’s code.'),
      signIn('Sign in'),
      h('a', { class: 'btn btn-ghost', href: '#/welcome' }, 'What is The Usual?'));
  }
  const name = pg.display_name || 'Bartender';
  const today = pg.today;
  const [avatars, photos] = await Promise.all([
    photoUrls('avatars', [pg.photo_path]),
    photoUrls('post-photos', pg.posts.map((p) => p.photo_path)),
  ]);
  const avatarUrl = avatars[pg.photo_path];
  const tonight = pg.shifts.filter((s) => s.occurrence_date === today);
  const later = pg.shifts.filter((s) => s.occurrence_date !== today);

  return screen(
    h('header', { class: 'profile-head' },
      avatar(avatarUrl, name, 'avatar-xl'),
      h('h1', {}, name),
      pg.bio ? h('p', { class: 'lead' }, pg.bio) : null,
    ),

    h('section', { class: 'card tonight', 'aria-labelledby': 'tonight-h' },
      h('p', { class: 'eyebrow', id: 'tonight-h' }, 'Tonight'),
      tonight.length
        ? tonight.map((s) => h('p', { class: 'shift-line' }, h('strong', {}, s.bar_name), ' · ', fmtShift(s.start_time, s.end_time),
            s.note ? h('span', { class: 'help block' }, s.note) : null))
        : h('p', { class: 'shift-line muted' }, 'Off tonight'),
    ),

    h('section', { 'aria-labelledby': 'coming-h' },
      h('h2', { id: 'coming-h' }, 'Coming up'),
      later.length
        ? h('ul', { class: 'plain-list schedule-list' }, later.map((s) => h('li', {},
            h('span', { class: 'day-label' }, dayLabel(s.occurrence_date, today)),
            h('span', {}, h('strong', {}, s.bar_name), ' · ', fmtShift(s.start_time, s.end_time),
              s.note ? h('span', { class: 'help block' }, s.note) : null))))
        : h('p', { class: 'muted' }, 'No shifts posted for the next two weeks.'),
    ),

    pg.bars.length
      ? h('section', { 'aria-labelledby': 'bars-h' },
          h('h2', { id: 'bars-h' }, `Where to find ${name}`),
          h('ul', { class: 'plain-list' }, pg.bars.map((x) => h('li', { class: 'bar-item' },
            h('strong', {}, x.name), x.area ? h('span', { class: 'help' }, ` · ${x.area}`) : null))))
      : null,

    pg.posts.length
      ? h('section', { 'aria-labelledby': 'posts-h' },
          h('h2', { id: 'posts-h' }, 'Updates'),
          pg.posts.map((p) => postCard(p, { name, avatarUrl, photo: photos[p.photo_path], href: `#/b/${pid}` })))
      : null,

    h('div', { class: 'card note stack' },
      h('p', {}, `Regulars see all of ${name}’s updates, and can react and reply. Sign in, then ask ${name} for today’s code to follow.`),
      signIn('Sign in to follow'),
      h('a', { class: 'btn btn-ghost', href: '#/welcome' }, 'What is The Usual?')),
  );
}
