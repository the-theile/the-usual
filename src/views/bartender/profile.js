import { h, screen, backLink, actionButton, confirmDialog } from '../../lib/dom.js';
import { supabase } from '../../supabase.js';
import { me, uid, loadMe } from '../../state.js';
import { compressImage, uploadPhoto, photoUrl } from '../../lib/images.js';
import { toast, oops } from '../../lib/toast.js';
import { loadBars } from './schedule.js';

function timezones() {
  let list = [];
  try { list = Intl.supportedValuesOf('timeZone'); } catch { /* old browser */ }
  if (!list.includes(me.bartender.timezone)) list = [me.bartender.timezone, ...list];
  return list;
}

export async function profileView({ query }) {
  const setup = query.get('setup') === '1';
  const b = me.bartender;
  const [bars, avatar] = await Promise.all([loadBars(), photoUrl('avatars', b.photo_path)]);

  // --- Photo ---
  const img = h('img', { class: 'avatar avatar-xl', alt: 'Your photo', src: avatar || '/icon.svg' });
  const file = h('input', { id: 'avatar', type: 'file', accept: 'image/*', class: 'visually-hidden' });
  const photoLabel = h('label', { for: 'avatar', class: 'btn btn-secondary' }, avatar ? 'Change my photo' : 'Add my photo');
  file.addEventListener('change', async () => {
    const f = file.files?.[0];
    if (!f) return;
    photoLabel.textContent = 'Uploading…';
    try {
      const blob = await compressImage(f, { maxSize: 512, square: true, quality: 0.82 });
      const path = await uploadPhoto('avatars', uid(), blob);
      const old = me.bartender.photo_path;
      const { error } = await supabase.from('bartenders').update({ photo_path: path }).eq('id', b.id);
      if (error) throw error;
      if (old) await supabase.storage.from('avatars').remove([old]);
      me.bartender.photo_path = path;
      img.src = URL.createObjectURL(blob);
      photoLabel.textContent = 'Change my photo';
      toast('Photo saved');
    } catch (e) {
      photoLabel.textContent = 'Add my photo';
      oops(e, "Couldn't save that photo. Try another one.");
    }
    file.value = '';
  });

  // --- Name, bio, timezone ---
  const name = h('input', { id: 'name', type: 'text', maxlength: 40, value: me.profile.display_name, required: true, autocapitalize: 'words' });
  const bio = h('textarea', { id: 'bio', rows: 3, maxlength: 300, value: b.bio, placeholder: 'e.g. Tiki drinks and terrible puns. Ask me about rum.' });
  const tz = h('select', { id: 'tz', value: b.timezone },
    timezones().map((z) => h('option', { value: z }, z.replace(/_/g, ' '))));
  const err = h('p', { class: 'error', role: 'alert' });
  const detailsForm = h('form', { class: 'stack', novalidate: true },
    h('div', { class: 'stack-tight' }, h('label', { for: 'name' }, 'Your name'), name,
      h('p', { class: 'help' }, 'Shown to your regulars.')),
    h('div', { class: 'stack-tight' }, h('label', { for: 'bio' }, 'A little about you (optional)'), bio),
    h('div', { class: 'stack-tight' }, h('label', { for: 'tz' }, 'Your time zone'), tz,
      h('p', { class: 'help' }, 'Your shift times and daily code use this.')),
    err,
    h('button', { type: 'submit', class: 'btn btn-primary' }, 'Save'),
  );
  detailsForm.addEventListener('submit', async (e) => {
    e.preventDefault();
    if (!name.value.trim()) { err.textContent = 'Please enter your name.'; name.focus(); return; }
    err.textContent = '';
    const [r1, r2] = await Promise.all([
      supabase.from('profiles').update({ display_name: name.value.trim() }).eq('id', uid()),
      supabase.from('bartenders').update({ bio: bio.value.trim(), timezone: tz.value }).eq('id', b.id),
    ]);
    if (r1.error || r2.error) return oops(r1.error || r2.error);
    await loadMe();
    toast('Saved');
  });

  // --- Bars ---
  const barList = h('div', { class: 'stack-tight' });
  const renderBars = (list) => {
    barList.replaceChildren(...(list.length ? list.map(barRow) : [h('p', { class: 'muted' }, 'No bars yet.')]));
  };
  function barRow(bar) {
    return h('div', { class: 'card row' },
      h('span', {}, h('strong', {}, bar.name), bar.area ? h('span', { class: 'help block' }, bar.area) : null),
      actionButton('Remove', async () => {
        const ok = await confirmDialog({
          title: `Remove ${bar.name}?`,
          body: 'Any shifts you’ve added at this bar will be removed too.',
          confirmText: 'Remove', danger: true, cancelText: 'Keep it',
        });
        if (!ok) return;
        const { error } = await supabase.from('bars').delete().eq('id', bar.id);
        if (error) return oops(error);
        renderBars(await loadBars());
      }, { class: 'btn btn-small btn-ghost' }));
  }
  renderBars(bars);

  const barName = h('input', { id: 'bar-name', type: 'text', maxlength: 60, placeholder: 'e.g. The Tiki Bar', required: true });
  const barArea = h('input', { id: 'bar-area', type: 'text', maxlength: 60, placeholder: 'e.g. Main St, Northside' });
  const barErr = h('p', { class: 'error', role: 'alert' });
  const barForm = h('form', { class: 'stack card', novalidate: true },
    h('h3', {}, 'Add a bar'),
    h('div', { class: 'stack-tight' }, h('label', { for: 'bar-name' }, 'Bar name'), barName),
    h('div', { class: 'stack-tight' }, h('label', { for: 'bar-area' }, 'Street or neighbourhood (optional)'), barArea),
    barErr,
    h('button', { type: 'submit', class: 'btn btn-secondary' }, 'Add bar'),
  );
  barForm.addEventListener('submit', async (e) => {
    e.preventDefault();
    if (!barName.value.trim()) { barErr.textContent = 'Please enter the bar’s name.'; barName.focus(); return; }
    barErr.textContent = '';
    const current = await loadBars();
    const { error } = await supabase.from('bars').insert({
      bartender_id: b.id, name: barName.value.trim(), area: barArea.value.trim(), sort: current.length,
    });
    if (error) return oops(error);
    barName.value = ''; barArea.value = '';
    renderBars(await loadBars());
    toast('Bar added');
  });

  return screen(
    setup ? null : backLink('#/'),
    h('h1', {}, setup ? 'Set up your page' : 'My profile & bars'),
    setup ? h('p', { class: 'lead' }, 'Add a photo so regulars recognise you, and the bars where you work. You can change all of this later.') : null,
    h('section', { class: 'center stack' }, img, file, photoLabel),
    h('section', { 'aria-labelledby': 'bars-h' }, h('h2', { id: 'bars-h' }, 'Where I work'), barList, barForm),
    h('section', { 'aria-labelledby': 'about-h' }, h('h2', { id: 'about-h' }, 'About me'), detailsForm),
    setup
      ? h('div', { class: 'stack' },
          h('a', { class: 'btn btn-primary btn-xl', href: '#/schedule' }, 'Next: add my shifts'),
          h('a', { class: 'btn btn-ghost', href: '#/' }, 'Do this later'))
      : null,
  );
}

