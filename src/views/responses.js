// Reactions and private replies on posts.
//   Regulars: react from a fixed set (they see counts only) and have a private
//   conversation with the bartender under each post (#/p/:id).
//   Bartenders: see who reacted and answer each conversation (#/responses/:id).
// Rules live in the database (migration 0006); this file only mirrors them for UI.
import { h, screen, backLink, actionButton, confirmDialog, clear, append } from '../lib/dom.js';
import { supabase } from '../supabase.js';
import { me, uid } from '../state.js';
import { timeAgo } from '../lib/time.js';
import { photoUrls } from '../lib/images.js';
import { toast, oops } from '../lib/toast.js';
import { avatar, postCard } from './regular/home.js';

export const REACTIONS = [
  { key: 'cheers', emoji: '🍻', label: 'Cheers' },
  { key: 'love',   emoji: '❤️', label: 'Love it' },
  { key: 'laugh',  emoji: '😂', label: 'Funny' },
  { key: 'fire',   emoji: '🔥', label: 'Fire' },
  { key: 'eyes',   emoji: '👀', label: 'Interested' },
  { key: 'clap',   emoji: '👏', label: 'Applause' },
];
const EMOJI = Object.fromEntries(REACTIONS.map((r) => [r.key, r.emoji]));

const OPEN_DAYS = 7;
const MAX_BODY = 500;
const MAX_MESSAGES = 20;

export const isOpen = (createdAt) => Date.now() - new Date(createdAt).getTime() < OPEN_DAYS * 86400000;

function responseError(e) {
  const m = e?.message || '';
  if (m.includes('closed')) return oops(e, 'Replies close a week after an update is posted.');
  if (m.includes('thread_full')) return oops(e, `This conversation is full (${MAX_MESSAGES} messages).`);
  if (m.includes('not_found')) return oops(e, 'This update isn’t available any more.');
  return oops(e);
}

// ===== Loading (regular side) =====

/** Reaction counts + my conversation summary for a list of posts. */
export async function loadRegularResponses(postIds) {
  const counts = {};   // postId -> { reactionKey: { n, mine } }
  const threads = {};  // postId -> { n, lastFromBartender }
  if (!postIds.length) return { counts, threads };
  const [c, r] = await Promise.all([
    supabase.rpc('post_reaction_counts', { p_posts: postIds }),
    supabase.from('post_replies').select('post_id, author_id, created_at')
      .in('post_id', postIds).order('created_at'),
  ]);
  for (const row of c.data || []) {
    (counts[row.post_id] ||= {})[row.reaction] = { n: row.n, mine: row.mine };
  }
  for (const row of r.data || []) {
    const t = (threads[row.post_id] ||= { n: 0, lastFromBartender: false });
    t.n += 1;
    t.lastFromBartender = row.author_id !== uid();
  }
  return { counts, threads };
}

// ===== Regular: footer under each post =====

export function regularPostFooter(p, bartenderName, { counts = {}, thread, readOnly = false } = {}) {
  if (readOnly) {   // public post seen by a non-regular: counts only
    return Object.keys(counts).length ? h('div', { class: 'post-responses' }, reactionBar(p, counts, false)) : null;
  }
  const open = isOpen(p.created_at);
  const label = thread?.lastFromBartender ? `${bartenderName} answered you`
    : thread?.n ? `Your conversation (${thread.n})`
    : open ? `Reply to ${bartenderName}` : null;
  return h('div', { class: 'post-responses' },
    reactionBar(p, counts, open),
    label ? h('a', { class: `reply-link${thread?.lastFromBartender ? ' has-answer' : ''}`, href: `#/p/${p.id}` },
      h('span', { 'aria-hidden': 'true' }, '💬'), label, h('span', { class: 'chev', 'aria-hidden': 'true' }, '›')) : null,
  );
}

function reactionBar(p, counts, open) {
  const state = structuredClone(counts);
  const bar = h('div', { class: 'reactions', role: 'group', 'aria-label': 'Reactions' });

  function draw() {
    append(clear(bar), REACTIONS.map((r) => {
      const c = state[r.key] || { n: 0, mine: false };
      if (!open && !c.n) return null;
      return h('button', {
        type: 'button', class: `reaction${c.mine ? ' mine' : ''}`,
        'aria-pressed': c.mine ? 'true' : 'false',
        'aria-label': `${r.label}${c.n ? `, ${c.n}` : ''}`,
        disabled: !open,
        onClick: () => toggle(r.key),
      }, h('span', { 'aria-hidden': 'true' }, r.emoji), c.n ? h('span', { class: 'reaction-n' }, c.n) : null);
    }));
  }

  let busy = false;
  async function toggle(key) {
    if (busy) return;
    busy = true;
    const before = structuredClone(state);
    const current = Object.keys(state).find((k) => state[k].mine);
    if (current) { state[current].n -= 1; state[current].mine = false; if (!state[current].n) delete state[current]; }
    const next = current === key ? null : key;
    if (next) { state[next] ||= { n: 0, mine: false }; state[next].n += 1; state[next].mine = true; }
    draw();   // optimistic
    const { error } = await supabase.rpc('react_to_post', { p_post: p.id, p_reaction: next });
    if (error) { Object.keys(state).forEach((k) => delete state[k]); Object.assign(state, before); draw(); responseError(error); }
    busy = false;
  }

  draw();
  return bar;
}

// ===== Conversation (shared) =====

function messageItem(m, { mine, authorName, open, onDeleted }) {
  const li = h('li', { class: `msg ${mine ? 'msg-mine' : 'msg-theirs'}` });

  function show() {
    append(clear(li), [
      h('p', { class: 'msg-who help' }, mine ? 'You' : authorName, ' · ', timeAgo(m.created_at), m.edited_at ? ' · edited' : ''),
      h('p', { class: 'msg-body' }, m.body),
      mine ? h('div', { class: 'msg-actions' },
        open ? h('button', { type: 'button', class: 'btn btn-small btn-ghost', onClick: edit }, 'Edit') : null,
        actionButton('Delete', async () => {
          const ok = await confirmDialog({ title: 'Delete this message?', confirmText: 'Delete', danger: true, cancelText: 'Cancel' });
          if (!ok) return;
          const { error } = await supabase.rpc('delete_reply', { p_reply: m.id });
          if (error) return responseError(error);
          li.remove();
          onDeleted?.();
          toast('Message deleted');
        }, { class: 'btn btn-small btn-ghost' })) : null,
    ]);
  }

  function edit() {
    const ta = h('textarea', { rows: 3, maxlength: MAX_BODY, 'aria-label': 'Edit your message', value: m.body });
    li.replaceChildren(ta, h('div', { class: 'msg-actions' },
      actionButton('Save', async () => {
        const body = ta.value.trim();
        if (!body) { ta.focus(); return; }
        const { error } = await supabase.rpc('edit_reply', { p_reply: m.id, p_body: body });
        if (error) return responseError(error);
        if (body !== m.body) { m.body = body; m.edited_at = new Date().toISOString(); }
        show();
      }, { class: 'btn btn-small btn-primary' }),
      h('button', { type: 'button', class: 'btn btn-small btn-ghost', onClick: show }, 'Cancel')));
    ta.focus();
  }

  show();
  return li;
}

/** Message list + compose box for one conversation. */
function conversation({ messages, postId, regularId, open, otherName, placeholder }) {
  const list = h('ol', { class: 'plain-list msgs', 'aria-label': 'Messages' });
  let count = messages.length;
  const add = (m) => list.append(messageItem(m, {
    mine: m.author_id === uid(), authorName: otherName, open, onDeleted: () => { count -= 1; refresh(); },
  }));
  messages.forEach(add);

  const ta = h('textarea', { rows: 3, maxlength: MAX_BODY, placeholder, 'aria-label': 'Your message' });
  const counter = h('p', { class: 'help counter', 'aria-live': 'polite' }, `0 / ${MAX_BODY}`);
  ta.addEventListener('input', () => { counter.textContent = `${ta.value.length} / ${MAX_BODY}`; });
  const send = h('button', { type: 'submit', class: 'btn btn-primary' }, 'Send');
  const form = h('form', { class: 'stack-tight', novalidate: true }, ta, counter, send);
  const note = h('p', { class: 'help' });

  function refresh() {
    const full = count >= MAX_MESSAGES;
    form.hidden = !open || full;
    note.textContent = !open ? 'Replies close a week after an update is posted.'
      : full ? `This conversation is full (${MAX_MESSAGES} messages).` : '';
  }

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const body = ta.value.trim();
    if (!body) { ta.focus(); return; }
    send.disabled = true;
    const { data: id, error } = await supabase.rpc('send_reply', { p_post: postId, p_body: body, p_regular: regularId });
    send.disabled = false;
    if (error) return responseError(error);
    add({ id, author_id: uid(), body, created_at: new Date().toISOString(), edited_at: null });
    count += 1;
    ta.value = ''; counter.textContent = `0 / ${MAX_BODY}`;
    refresh();
  });

  refresh();
  return h('div', { class: 'stack-tight' }, list, form, note);
}

async function loadPost(id) {
  const { data: p } = await supabase.from('posts')
    .select('id, bartender_id, body, photo_path, created_at, visibility, bartenders(public_id, photo_path, profiles!bartenders_id_fkey(display_name))')
    .eq('id', id).maybeSingle();
  return p;
}

const notFound = () => screen(backLink('#/'), h('h1', {}, 'Update not found'),
  h('p', { class: 'lead' }, 'This update isn’t available any more.'));

// ===== #/p/:id — regular's private conversation under a post =====

export async function regularThreadView({ params }) {
  const p = await loadPost(params.id);
  if (!p || p.bartender_id === uid()) return p ? bartenderResponsesView({ params }) : notFound();
  const b = p.bartenders;
  const name = b?.profiles?.display_name || 'Bartender';

  const [{ data: messages }, avatars, photos, { counts }, { data: conn }] = await Promise.all([
    supabase.from('post_replies').select('id, author_id, body, created_at, edited_at').eq('post_id', p.id).order('created_at'),
    photoUrls('avatars', [b?.photo_path]),
    photoUrls('post-photos', [p.photo_path]),
    loadRegularResponses([p.id]),
    supabase.from('connections').select('bartender_id').eq('bartender_id', p.bartender_id).eq('regular_id', uid()).maybeSingle(),
  ]);
  const open = isOpen(p.created_at);

  if (!conn) {   // a public post, seen by someone who doesn't follow this bartender
    return screen(
      backLink(`#/b/${b.public_id}`),
      postCard(p, { name, avatarUrl: avatars[b?.photo_path], photo: photos[p.photo_path], href: `#/b/${b.public_id}`,
        footer: regularPostFooter(p, name, { counts: counts[p.id] || {}, readOnly: true }) }),
      h('div', { class: 'card note stack' },
        h('p', {}, `Only ${name}’s regulars can react and reply. Ask ${name} for today’s code to follow.`),
        h('a', { class: 'btn btn-primary', href: '#/code' }, 'I have a code')),
    );
  }

  return screen(
    backLink('#/'),
    postCard(p, { name, avatarUrl: avatars[b?.photo_path], photo: photos[p.photo_path], href: `#/b/${b.public_id}`,
      footer: h('div', { class: 'post-responses' }, reactionBar(p, counts[p.id] || {}, open)) }),
    h('section', { 'aria-labelledby': 'convo-h' },
      h('h2', { id: 'convo-h' }, `Reply to ${name}`),
      h('p', { class: 'help' }, `Only you and ${name} can see this.`),
      conversation({ messages: messages || [], postId: p.id, regularId: null, open, otherName: name,
        placeholder: `Say something to ${name}…` })),
  );
}

// ===== Bartender: summary line on own posts (home) =====

/** { postId: { reactions, replies, unread } } for the bartender's own posts. */
export async function loadMyPostActivity(postIds) {
  if (!postIds.length) return {};
  const { data } = await supabase.rpc('my_post_activity', { p_posts: postIds });
  return Object.fromEntries((data || []).map((r) => [r.post_id, r]));
}

export function activityLink(p, a) {
  if (!a || (!a.reactions && !a.replies)) {
    return isOpen(p.created_at) ? h('p', { class: 'help' }, 'No reactions or replies yet.') : null;
  }
  const parts = [];
  if (a.reactions) parts.push(`${a.reactions} reaction${a.reactions > 1 ? 's' : ''}`);
  if (a.replies) parts.push(`${a.replies} repl${a.replies > 1 ? 'ies' : 'y'}`);
  return h('a', { class: 'reply-link', href: `#/responses/${p.id}` },
    parts.join(' · '),
    a.unread ? h('span', { class: 'badge' }, `${a.unread} new`) : null,
    h('span', { class: 'chev', 'aria-hidden': 'true' }, '›'));
}

// ===== #/responses/:id — bartender: who reacted + every conversation =====

export async function bartenderResponsesView({ params }) {
  const p = await loadPost(params.id);
  if (!p || p.bartender_id !== uid()) return notFound();

  const [rx, rp, photos] = await Promise.all([
    supabase.from('post_reactions').select('regular_id, reaction, created_at, profiles!post_reactions_regular_id_fkey(display_name)')
      .eq('post_id', p.id).order('created_at', { ascending: false }),
    supabase.from('post_replies').select('id, regular_id, author_id, body, created_at, edited_at, profiles!post_replies_regular_id_fkey(display_name)')
      .eq('post_id', p.id).order('created_at'),
    photoUrls('post-photos', [p.photo_path]),
  ]);
  supabase.rpc('mark_post_seen', { p_post: p.id }).then(({ error }) => error && console.error(error));

  const open = isOpen(p.created_at);
  const reactions = rx.data || [];

  // Faces + usual drinks of everyone who responded (RLS: only this bartender's regulars).
  const people = [...new Set([...reactions.map((r) => r.regular_id), ...(rp.data || []).map((m) => m.regular_id)])];
  const { data: details } = people.length
    ? await supabase.from('regular_details').select('id, photo_path, usual').in('id', people)
    : { data: [] };
  const det = Object.fromEntries((details || []).map((d) => [d.id, d]));
  const faces = await photoUrls('regular-photos', (details || []).map((d) => d.photo_path));
  const face = (rid, name) => avatar(faces[det[rid]?.photo_path], name, 'avatar-sm');
  const byRegular = new Map();
  for (const m of rp.data || []) {
    if (!byRegular.has(m.regular_id)) byRegular.set(m.regular_id, { name: m.profiles?.display_name || 'Regular', messages: [] });
    byRegular.get(m.regular_id).messages.push(m);
  }
  // Most recent activity first.
  const threads = [...byRegular.entries()].sort((a, b) =>
    b[1].messages.at(-1).created_at.localeCompare(a[1].messages.at(-1).created_at));

  return screen(
    backLink('#/'),
    h('h1', {}, 'Reactions & replies'),
    postCard(p, { name: me.profile.display_name, avatarUrl: null, photo: photos[p.photo_path], href: `#/b/${me.bartender.public_id}` }),

    h('section', { 'aria-labelledby': 'rx-h' },
      h('h2', { id: 'rx-h' }, 'Reactions'),
      reactions.length
        ? h('ul', { class: 'plain-list who-reacted' }, reactions.map((r) => h('li', {},
            face(r.regular_id, r.profiles?.display_name),
            h('span', { class: 'who-emoji', 'aria-hidden': 'true' }, EMOJI[r.reaction]),
            h('a', { class: 'who-name', href: `#/regulars/${r.regular_id}` }, r.profiles?.display_name || 'Regular'),
            h('span', { class: 'help' }, ` · ${timeAgo(r.created_at)}`))))
        : h('p', { class: 'muted' }, 'No reactions yet.'),
      h('p', { class: 'help' }, 'Your regulars see how many of each, not who.')),

    h('section', { 'aria-labelledby': 'rp-h' },
      h('h2', { id: 'rp-h' }, 'Replies'),
      h('p', { class: 'help' }, 'Each conversation is private between you and that regular.'),
      threads.length
        ? threads.map(([rid, t]) => h('article', { class: 'card stack-tight' },
            h('a', { class: 'thread-head', href: `#/regulars/${rid}` },
              face(rid, t.name),
              h('span', {}, h('h3', { class: 'thread-name' }, t.name),
                det[rid]?.usual ? h('span', { class: 'help block' }, `🍸 ${det[rid].usual}`) : null)),
            conversation({ messages: t.messages, postId: p.id, regularId: rid, open, otherName: t.name,
              placeholder: `Answer ${t.name}…` })))
        : h('p', { class: 'muted' }, open ? 'No replies yet.' : 'No replies. Replies are closed for this update.')),
  );
}
