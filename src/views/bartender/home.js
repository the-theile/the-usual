import { h, screen, actionButton, confirmDialog } from '../../lib/dom.js';
import { supabase } from '../../supabase.js';
import { me, setMode } from '../../state.js';
import { navigate } from '../../router.js';
import { barDay, fmtShift, timeAgo } from '../../lib/time.js';
import { photoUrls } from '../../lib/images.js';
import { toast, oops } from '../../lib/toast.js';

export async function bartenderHomeView() {
  const b = me.bartender;
  const today = barDay(b.timezone);

  const [tonightRes, postsRes, barsRes] = await Promise.all([
    supabase.rpc('get_schedule', { p_bartenders: [b.id], p_from: today, p_to: today }),
    supabase.from('posts').select('id, body, photo_path, created_at').eq('bartender_id', b.id)
      .order('created_at', { ascending: false }).limit(10),
    supabase.from('bars').select('id').eq('bartender_id', b.id).limit(1),
  ]);
  const tonight = (tonightRes.data || []).filter((s) => !s.cancelled);
  const posts = postsRes.data || [];
  const hasBars = (barsRes.data || []).length > 0;
  const urls = await photoUrls('post-photos', posts.map((p) => p.photo_path));

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

    h('nav', { class: 'menu', 'aria-label': 'More' },
      h('a', { class: 'menu-row', href: '#/schedule' }, 'My schedule', h('span', { 'aria-hidden': 'true' }, '›')),
      h('a', { class: 'menu-row', href: '#/regulars' }, 'My regulars', h('span', { 'aria-hidden': 'true' }, '›')),
      h('a', { class: 'menu-row', href: '#/profile' }, 'My profile & bars', h('span', { 'aria-hidden': 'true' }, '›')),
      h('a', { class: 'menu-row', href: `#/b/${b.public_id}` }, 'See my page as regulars do', h('span', { 'aria-hidden': 'true' }, '›')),
      h('button', {
        type: 'button', class: 'menu-row',
        onClick: () => { setMode('regular'); navigate('/'); },
      }, 'Bartenders I follow', h('span', { 'aria-hidden': 'true' }, '›')),
    ),

    h('section', { 'aria-labelledby': 'my-posts' },
      h('h2', { id: 'my-posts' }, 'My recent updates'),
      posts.length
        ? posts.map((p) => ownPost(p, urls[p.photo_path]))
        : h('p', { class: 'muted' }, 'Nothing posted yet. Tap “Post an update” to share tonight’s special.'),
    ),

    h('button', { type: 'button', class: 'btn btn-ghost', onClick: signOut }, 'Sign out'),
  );
}

function ownPost(p, url) {
  const card = h('article', { class: 'card post' },
    url ? h('img', { class: 'post-photo', src: url, alt: 'Photo for this update', loading: 'lazy' }) : null,
    p.body ? h('p', { class: 'post-body' }, p.body) : null,
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

export async function signOut() {
  const ok = await confirmDialog({ title: 'Sign out?', body: 'You can sign back in any time with your phone number.', confirmText: 'Sign out' });
  if (ok) await supabase.auth.signOut();
}
