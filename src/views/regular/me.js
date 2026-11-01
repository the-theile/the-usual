// #/me — a regular's own profile: name, photo, "my usual", birthday.
// Photo, usual and birthday live in public.regular_details, which only the person
// and the bartenders they follow can read (migration 0008).
import { h, screen, backLink, actionButton, confirmDialog } from '../../lib/dom.js';
import { supabase } from '../../supabase.js';
import { me, uid, loadMe } from '../../state.js';
import { compressImage, uploadPhoto, photoUrl } from '../../lib/images.js';
import { MONTHS, daysInMonth } from '../../lib/time.js';
import { toast, oops } from '../../lib/toast.js';
import { avatar } from './home.js';
import { deleteAccountSection } from '../account.js';

const BUCKET = 'regular-photos';

export async function loadMyDetails() {
  const { data, error } = await supabase.from('regular_details')
    .select('id, photo_path, usual, birthday_month, birthday_day').eq('id', uid()).maybeSingle();
  if (error) throw error;
  return data;
}

export async function regularProfileView() {
  let details = await loadMyDetails();
  const photo = await photoUrl(BUCKET, details?.photo_path);

  // Insert the row the first time, update it after that.
  async function save(fields) {
    const res = details
      ? await supabase.from('regular_details').update(fields).eq('id', uid())
      : await supabase.from('regular_details').insert({ id: uid(), ...fields });
    if (res.error) throw res.error;
    details = { ...(details || { id: uid(), photo_path: null, usual: '', birthday_month: null, birthday_day: null }), ...fields };
  }

  // --- Photo ---
  const photoBox = h('div', { class: 'center' });
  const showPhoto = (url) => photoBox.replaceChildren(
    url ? h('img', { class: 'avatar avatar-xl', src: url, alt: 'Your photo' }) : avatar(null, me.profile.display_name, 'avatar-xl'));
  showPhoto(photo);

  const file = h('input', { id: 'photo', type: 'file', accept: 'image/*', class: 'visually-hidden' });
  const photoLabel = h('label', { for: 'photo', class: 'btn btn-secondary' }, photo ? 'Change my photo' : 'Add my photo');
  const removeBtn = actionButton('Remove my photo', async () => {
    const ok = await confirmDialog({ title: 'Remove your photo?', confirmText: 'Remove', cancelText: 'Keep it', danger: true });
    if (!ok) return;
    const old = details?.photo_path;
    try {
      await save({ photo_path: null });
      if (old) await supabase.storage.from(BUCKET).remove([old]);
      showPhoto(null);
      photoLabel.textContent = 'Add my photo';
      removeBtn.hidden = true;
      toast('Photo removed');
    } catch (e) { oops(e); }
  }, { class: 'btn btn-ghost', hidden: !photo });

  file.addEventListener('change', async () => {
    const f = file.files?.[0];
    if (!f) return;
    photoLabel.textContent = 'Uploading…';
    try {
      const blob = await compressImage(f, { maxSize: 512, square: true, quality: 0.82 });
      const path = await uploadPhoto(BUCKET, uid(), blob);
      const old = details?.photo_path;
      await save({ photo_path: path });
      if (old) await supabase.storage.from(BUCKET).remove([old]);
      showPhoto(URL.createObjectURL(blob));
      photoLabel.textContent = 'Change my photo';
      removeBtn.hidden = false;
      toast('Photo saved');
    } catch (e) {
      photoLabel.textContent = details?.photo_path ? 'Change my photo' : 'Add my photo';
      oops(e, "Couldn't save that photo. Try another one.");
    }
    file.value = '';
  });

  // --- Name, usual, birthday ---
  const name = h('input', { id: 'name', type: 'text', maxlength: 40, value: me.profile.display_name, required: true, autocapitalize: 'words' });
  const usual = h('input', { id: 'usual', type: 'text', maxlength: 60, value: details?.usual || '',
    placeholder: 'e.g. Mezcal Negroni, up', 'aria-describedby': 'usual-help' });

  const month = h('select', { id: 'bday-month', 'aria-label': 'Birthday month', value: String(details?.birthday_month || '') },
    h('option', { value: '' }, 'Month'),
    MONTHS.map((m, i) => h('option', { value: String(i + 1) }, m)));
  const day = h('select', { id: 'bday-day', 'aria-label': 'Birthday day' });
  const fillDays = (keep) => {
    const n = month.value ? daysInMonth(Number(month.value)) : 31;
    day.replaceChildren(h('option', { value: '' }, 'Day'),
      ...Array.from({ length: n }, (_, i) => h('option', { value: String(i + 1) }, String(i + 1))));
    day.value = keep && Number(keep) <= n ? String(keep) : '';
  };
  fillDays(details?.birthday_day);
  month.addEventListener('change', () => fillDays(day.value));

  const err = h('p', { class: 'error', role: 'alert' });
  const form = h('form', { class: 'stack', novalidate: true },
    h('div', { class: 'stack-tight' }, h('label', { for: 'name' }, 'Your name'), name),
    h('div', { class: 'stack-tight' }, h('label', { for: 'usual' }, 'My usual (optional)'), usual,
      h('p', { id: 'usual-help', class: 'help' }, 'Your go-to drink, so your bartender can have it ready.')),
    h('fieldset', { class: 'stack-tight' },
      h('legend', {}, 'My birthday (optional)'),
      h('div', { class: 'bday-row' }, month, day),
      h('p', { class: 'help' }, 'Just the day, not the year. Your bartenders see it coming up.')),
    err,
    h('button', { type: 'submit', class: 'btn btn-primary' }, 'Save'),
  );
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    err.textContent = '';
    if (!name.value.trim()) { err.textContent = 'Please type a name.'; name.focus(); return; }
    if (!!month.value !== !!day.value) { err.textContent = 'Please pick both a month and a day, or neither.'; (month.value ? day : month).focus(); return; }
    const btn = form.querySelector('button[type=submit]');
    btn.disabled = true;
    try {
      const r = await supabase.from('profiles').update({ display_name: name.value.trim() }).eq('id', uid());
      if (r.error) throw r.error;
      await save({
        usual: usual.value.trim(),
        birthday_month: month.value ? Number(month.value) : null,
        birthday_day: day.value ? Number(day.value) : null,
      });
      await loadMe();
      toast('Saved');
    } catch (e2) { oops(e2); }
    btn.disabled = false;
  });

  return screen(
    backLink('#/'),
    h('h1', {}, me.bartender ? 'My regular profile' : 'My profile'),
    h('p', { class: 'lead' }, 'Help your bartenders recognise you.'),
    me.bartender ? h('p', { class: 'help' }, 'This is separate from your bartender profile. Your name is shared by both.') : null,
    h('section', { class: 'center stack' }, photoBox, file, photoLabel, removeBtn),
    form,
    h('p', { class: 'help' }, 'Only bartenders you follow can see your photo, usual and birthday. Other regulars never do.'),
    me.bartender ? null : deleteAccountSection(), // bartenders delete from My bartender profile & bars
  );
}
