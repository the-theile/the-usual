import { h, screen, backLink, actionButton, confirmDialog } from '../../lib/dom.js';
import { supabase } from '../../supabase.js';
import { navigate } from '../../router.js';
import { uid } from '../../state.js';
import { fmtDate, fmtBirthday } from '../../lib/time.js';
import { photoUrls } from '../../lib/images.js';
import { toast, oops } from '../../lib/toast.js';
import { avatar } from '../regular/home.js';
import { reportButton } from '../../lib/report.js';

const MAX_NOTE = 500;

export async function loadMyRegulars() {
  const { data, error } = await supabase.rpc('my_regulars');
  if (error) throw error;
  return data;
}

async function blockFlow(r) {
  const ok = await confirmDialog({
    title: `Block ${r.display_name}?`,
    body: `${r.display_name} won’t be told. They’ll stop seeing your updates, schedule and profile, and your codes and links won’t work for them.`,
    confirmText: `Block ${r.display_name}`, danger: true, cancelText: 'Cancel',
  });
  if (!ok) return false;
  const res = await supabase.rpc('block_regular', { p_regular: r.regular_id });
  if (res.error) { oops(res.error); return false; }
  toast(`${r.display_name} is blocked`);
  return true;
}

async function unblockFlow(r) {
  const ok = await confirmDialog({
    title: `Unblock ${r.display_name}?`,
    body: 'They won’t be reconnected. They’d need a new code or link from you to follow you again.',
    confirmText: 'Unblock', cancelText: 'Cancel',
  });
  if (!ok) return false;
  const res = await supabase.rpc('unblock_regular', { p_regular: r.regular_id });
  if (res.error) { oops(res.error); return false; }
  toast(`${r.display_name} is unblocked`);
  return true;
}

// ===== #/regulars =====

export async function regularsView() {
  const data = await loadMyRegulars();
  const regulars = data.filter((r) => !r.blocked);
  const blocked = data.filter((r) => r.blocked);
  const photos = await photoUrls('regular-photos', data.map((r) => r.photo_path));
  const reload = () => navigate('/regulars', { replace: true });

  return screen(
    backLink('#/'),
    h('h1', {}, 'My regulars'),
    h('p', { class: 'lead' }, regulars.length === 1 ? '1 person follows you.' : `${regulars.length} people follow you.`),

    regulars.length === 0
      ? h('div', { class: 'card note' },
          h('p', {}, 'No regulars yet. Show your QR code or say today’s code to your first one.'),
          h('a', { class: 'btn btn-primary', href: '#/invite' }, 'Invite a regular'))
      : h('ul', { class: 'plain-list stack-tight' }, regulars.map((r) => h('li', {},
          h('a', { class: 'card regular-card', href: `#/regulars/${r.regular_id}` },
            avatar(photos[r.photo_path], r.display_name),
            h('span', { class: 'rc-text' },
              h('strong', { class: 'rc-name' }, r.display_name),
              r.usual ? h('span', { class: 'rc-usual' }, `🍸 ${r.usual}`) : null,
              h('span', { class: 'help block' }, `Since ${fmtDate(r.since)}`, r.note ? ' · 📝 Note' : '')),
            h('span', { class: 'chev', 'aria-hidden': 'true' }, '›'))))),

    blocked.length
      ? h('section', { 'aria-labelledby': 'blocked-h' },
          h('h2', { id: 'blocked-h' }, 'Blocked'),
          h('p', { class: 'help' }, 'Only you can see this list.'),
          h('ul', { class: 'plain-list stack-tight' }, blocked.map((r) => h('li', { class: 'card row' },
            avatar(photos[r.photo_path], r.display_name, 'avatar-sm'),
            h('span', { class: 'grow' }, h('strong', {}, r.display_name), h('span', { class: 'help block' }, `Blocked ${fmtDate(r.since)}`)),
            actionButton('Unblock', async () => { if (await unblockFlow(r)) reload(); },
              { class: 'btn btn-small btn-ghost' })))))
      : null,
  );
}

// ===== #/regulars/:id — one regular: photo, usual, birthday, my private note =====

export async function regularDetailView({ params }) {
  const data = await loadMyRegulars();
  const r = data.find((x) => x.regular_id === params.id && !x.blocked);
  if (!r) {
    return screen(backLink('#/regulars'), h('h1', {}, 'Not found'),
      h('p', { class: 'lead' }, 'This person doesn’t follow you any more.'));
  }
  const photos = await photoUrls('regular-photos', [r.photo_path]);
  let hasNote = !!r.note;

  const note = h('textarea', { id: 'note', rows: 4, maxlength: MAX_NOTE, value: r.note || '',
    placeholder: 'e.g. Allergic to citrus. Partner is Dana. Likes the corner seat.', 'aria-describedby': 'note-help' });
  const err = h('p', { class: 'error', role: 'alert' });
  const form = h('form', { class: 'stack-tight', noValidate: true },
    h('label', { for: 'note' }, 'My note'),
    note,
    h('p', { id: 'note-help', class: 'help' }, `Only you can see this. ${r.display_name} is never shown it.`),
    err,
    h('button', { type: 'submit', class: 'btn btn-secondary' }, 'Save note'),
  );
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    err.textContent = '';
    const body = note.value.trim();
    const btn = form.querySelector('button');
    btn.disabled = true;
    let res;
    if (!body) {
      res = await supabase.from('regular_notes').delete().eq('regular_id', r.regular_id);
    } else if (hasNote) {
      res = await supabase.from('regular_notes').update({ body }).eq('regular_id', r.regular_id);
    } else {
      res = await supabase.from('regular_notes').insert({ bartender_id: uid(), regular_id: r.regular_id, body });
    }
    btn.disabled = false;
    if (res.error) return oops(res.error);
    hasNote = !!body;
    toast(body ? 'Note saved' : 'Note removed');
  });

  const birthday = fmtBirthday(r.birthday_month, r.birthday_day);

  return screen(
    backLink('#/regulars', 'My regulars'),
    h('section', { class: 'profile-head stack-tight' },
      photos[r.photo_path]
        ? h('img', { class: 'avatar avatar-xl', src: photos[r.photo_path], alt: `Photo of ${r.display_name}` })
        : avatar(null, r.display_name, 'avatar-xl'),
      h('h1', {}, r.display_name),
      h('p', { class: 'help' }, `Your regular since ${fmtDate(r.since)}`)),

    h('dl', { class: 'card facts' },
      h('dt', {}, 'Their usual'), h('dd', {}, r.usual || h('span', { class: 'muted' }, 'Not set')),
      h('dt', {}, 'Birthday'), h('dd', {}, birthday ? `🎂 ${birthday}` : h('span', { class: 'muted' }, 'Not set'))),

    h('section', { class: 'card' }, form),

    // After reporting, offer to block too (blockFlow asks first).
    reportButton('person', r.regular_id, r.display_name, {
      label: `Report ${r.display_name}`, className: 'btn btn-ghost',
      onDone: async () => { if (await blockFlow(r)) navigate('/regulars', { replace: true }); },
    }),
    actionButton(`Block ${r.display_name}`, async () => {
      if (await blockFlow(r)) navigate('/regulars', { replace: true });
    }, { class: 'btn btn-danger-outline' }),
  );
}
