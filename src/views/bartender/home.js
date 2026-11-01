import { h, screen, actionButton, confirmDialog } from '../../lib/dom.js';
import { supabase } from '../../supabase.js';
import { me, setMode } from '../../state.js';
import { navigate } from '../../router.js';
import { barDay, fmtShift, timeAgo, upcomingBirthdays, dayLabel } from '../../lib/time.js';
import { photoUrls } from '../../lib/images.js';
import { toast, oops } from '../../lib/toast.js';
import { loadMyPostActivity, activityLink } from '../responses.js';
import { loadMyRegulars } from './regulars.js';
import { avatar } from '../regular/home.js';
import { installTipCard, installMenuRow } from '../../lib/install.js';

export async function bartenderHomeView() {
  const b = me.bartender;
  const today = barDay(b.timezone);

  const [tonightRes, postsRes, barsRes, regulars] = await Promise.all([
    supabase.rpc('get_schedule', { p_bartenders: [b.id], p_from: today, p_to: today }),
    supabase.from('posts').select('id, body, photo_path, created_at, visibility').eq('bartender_id', b.id)
      .order('created_at', { ascending: false }).limit(10),
    supabase.from('bars').select('id').eq('bartender_id', b.id).limit(1),
    loadMyRegulars().catch((e) => { console.error(e); return []; }),
  ]);
  const birthdays = upcomingBirthdays(regulars.filter((r) => !r.blocked), today, 7);
  const tonight = (tonightRes.data || []).filter((s) => !s.cancelled);
  const posts = postsRes.data || [];
  const hasBars = (barsRes.data || []).length > 0;
  const [urls, activity, faces] = await Promise.all([
    photoUrls('post-photos', posts.map((p) => p.photo_path)),
    loadMyPostActivity(posts.map((p) => p.id)),
    photoUrls('regular-photos', birthdays.map((x) => x.person.photo_path)),
  ]);
  const unread = Object.values(activity).reduce((n, a) => n + a.unread, 0);

  return screen(
    h('header', { class: 'topbar' },
      h('p', { class: 'brand-small' }, 'The Usual'),
      h('h1', {}, `Hi, ${me.profile.display_name}`),
    ),

    // The two actions that matter most: one tap each.
    h('div', { class: 'primary-actions' },
      h('a', { class: 'btn btn-primary btn-hero', href: '#/post', 'data-autofocus': '' },
        h('span', { class: 'icon', 'aria-hidden': 'true' }, '✎'), 'Post an update'),
      h('a', { class: 'btn btn-secondary btn-hero', href: '#/invite' },
        h('span', { class: 'icon', 'aria-hidden': 'true' }, '＋'), 'Invite a regular'),
    ),

    h('a', { class: 'card tonight', href: '#/schedule' },
      h('p', { class: 'eyebrow' }, 'Tonight'),
      tonight.length
        ? tonight.map((s) => h('p', { class: 'shift-line' }, h('strong', {}, s.bar_name), ' · ', fmtShift(s.start_time, s.end_time)))
        : h('p', { class: 'shift-line muted' }, hasBars ? "You're off tonight" : 'Add your bars and shifts'),
      h('p', { class: 'link-text' }, 'Change my schedule ›'),
    ),

    birthdays.length
      ? h('section', { class: 'card birthdays', 'aria-labelledby': 'bd-h' },
          h('p', { class: 'eyebrow', id: 'bd-h' }, '🎂 Birthdays this week'),
          birthdays.map(({ person: r, ymd }) => h('a', { class: 'bd-line', href: `#/regulars/${r.regular_id}` },
            avatar(faces[r.photo_path], r.display_name, 'avatar-sm'),
            h('span', {}, h('strong', {}, r.display_name), ' · ', ymd === today ? 'Today!' : dayLabel(ymd, today))))
        )
      : null,

    installTipCard(),

    h('nav', { class: 'menu', 'aria-label': 'More' },
      h('a', { class: 'menu-row', href: '#/schedule' }, 'My schedule', h('span', { 'aria-hidden': 'true' }, '›')),
      h('a', { class: 'menu-row', href: '#/regulars' }, 'My regulars', h('span', { 'aria-hidden': 'true' }, '›')),
      h('a', { class: 'menu-row', href: '#/profile' }, 'My bartender profile & bars', h('span', { 'aria-hidden': 'true' }, '›')),
      h('a', { class: 'menu-row', href: `#/b/${b.public_id}` }, 'See my page as regulars do', h('span', { 'aria-hidden': 'true' }, '›')),
      me.moderator ? h('a', { class: 'menu-row', href: '#/mod' }, 'Moderator tools', h('span', { 'aria-hidden': 'true' }, '›')) : null,
      installMenuRow(),
      h('button', {
        type: 'button', class: 'menu-row',
        onClick: () => { setMode('regular'); navigate('/'); },
      }, 'Switch to my regular side', h('span', { 'aria-hidden': 'true' }, '›')),
    ),

    h('section', { 'aria-labelledby': 'my-posts' },
      h('h2', { id: 'my-posts' }, 'My recent updates',
        unread ? h('span', { class: 'badge' }, `${unread} new`) : null),
      posts.length
        ? posts.map((p) => ownPost(p, urls[p.photo_path], activity[p.id]))
        : h('p', { class: 'muted' }, 'Nothing posted yet. Tap “Post an update” to share tonight’s special.'),
    ),

    h('button', { type: 'button', class: 'btn btn-ghost', onClick: signOut }, 'Sign out'),
  );
}

function ownPost(p, url, activity) {
  const card = h('article', { class: 'card post' },
    url ? h('img', { class: 'post-photo', src: url, alt: 'Photo for this update', loading: 'lazy' }) : null,
    p.body ? h('p', { class: 'post-body' }, p.body) : null,
    activityLink(p, activity),
    visibilityRow(p),
    h('div', { class: 'post-meta' },
      h('span', { class: 'muted' }, timeAgo(p.created_at)),
      actionButton('Delete', async () => {
        const ok = await confirmDialog({ title: 'Delete this update?', body: 'Your regulars will no longer see it.', confirmText: 'Delete', danger: true });
        if (!ok) return;
        const { error } = await supabase.from('posts').delete().eq('id', p.id);
        if (error) return oops(error);
        if (p.photo_path) await supabase.storage.from('post-photos').remove([p.photo_path]);
        card.remove();
        toast('Update deleted');
      }, { class: 'btn btn-small btn-ghost' }),
    ),
  );
  return card;
}

// "🔒 Only my regulars" / "🌐 Public", with a one-tap switch.
function visibilityRow(p) {
  const row = h('div', { class: 'post-vis' });
  const draw = () => {
    const isPublic = p.visibility === 'public';
    row.replaceChildren(
      h('span', { class: 'help' }, isPublic ? '🌐 Public' : '🔒 Only my regulars'),
      actionButton(isPublic ? 'Make regulars-only' : 'Make public', async () => {
        const next = isPublic ? 'regulars' : 'public';
        const { error } = await supabase.from('posts').update({ visibility: next }).eq('id', p.id);
        if (error) return oops(error);
        p.visibility = next;
        toast(next === 'public'
          ? (me.bartender.schedule_visibility === 'public' ? 'Update is now public' : 'Update is public. It shows on your page once your schedule is set to “Anyone with my link”.')
          : 'Update is now for regulars only');
        draw();
      }, { class: 'btn btn-small btn-ghost' }));
  };
  draw();
  return row;
}

export async function signOut() {
  const ok = await confirmDialog({ title: 'Sign out?', body: 'You can sign back in any time with your phone number.', confirmText: 'Sign out' });
  if (ok) await supabase.auth.signOut();
}
