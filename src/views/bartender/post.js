import { h, screen, backLink } from '../../lib/dom.js';
import { supabase } from '../../supabase.js';
import { me, uid } from '../../state.js';
import { navigate } from '../../router.js';
import { compressImage, uploadPhoto } from '../../lib/images.js';
import { toast, oops } from '../../lib/toast.js';
import { barDay } from '../../lib/time.js';

const MAX = 500;

export async function postView() {
  const b = me.bartender;
  const today = barDay(b.timezone);
  const [barsRes, tonightRes] = await Promise.all([
    supabase.from('bars').select('id, name').eq('bartender_id', b.id).order('sort'),
    supabase.rpc('get_schedule', { p_bartenders: [b.id], p_from: today, p_to: today }),
  ]);
  const bars = barsRes.data || [];
  const tonightBars = new Set((tonightRes.data || []).filter((s) => !s.cancelled).map((s) => s.bar_id));
  const preselect = bars.find((x) => tonightBars.has(x.id))?.id || '';

  let photo = null; // compressed Blob
  let previewUrl = null;

  const text = h('textarea', {
    id: 'body', rows: 5, maxlength: MAX, 'data-autofocus': '',
    placeholder: 'Tonight’s special, a new menu, a photo of the bar…',
  });
  const counter = h('p', { class: 'help counter', 'aria-live': 'polite' }, `0 / ${MAX}`);
  text.addEventListener('input', () => { counter.textContent = `${text.value.length} / ${MAX}`; });

  const file = h('input', { id: 'photo', type: 'file', accept: 'image/*', class: 'visually-hidden' });
  const preview = h('div', { class: 'photo-preview' });
  const photoBtn = h('label', { for: 'photo', class: 'btn btn-secondary' }, '📷 Add a photo');
  const err = h('p', { class: 'error', role: 'alert' });

  function showPreview() {
    preview.replaceChildren();
    if (previewUrl) URL.revokeObjectURL(previewUrl);
    previewUrl = null;
    if (!photo) { photoBtn.textContent = '📷 Add a photo'; return; }
    previewUrl = URL.createObjectURL(photo);
    photoBtn.textContent = '📷 Change photo';
    preview.append(
      h('img', { src: previewUrl, alt: 'Your photo' }),
      h('button', { type: 'button', class: 'btn btn-small btn-ghost', onClick: () => { photo = null; file.value = ''; showPreview(); } }, 'Remove photo'),
    );
  }

  file.addEventListener('change', async () => {
    const f = file.files?.[0];
    if (!f) return;
    err.textContent = '';
    photoBtn.textContent = 'Getting photo ready…';
    try {
      photo = await compressImage(f, { maxSize: 1600, quality: 0.8 });
    } catch (e) {
      console.error(e);
      photo = null;
      err.textContent = "That photo couldn't be used. Try a different one.";
    }
    showPreview();
  });

  const visOption = (value, title, desc) => h('label', { class: 'choice' },
    h('input', { type: 'radio', name: 'vis', value, checked: value === 'regulars' }),
    h('span', {}, h('strong', {}, title), h('span', { class: 'help' }, desc)));
  const scheduleIsPublic = me.bartender.schedule_visibility === 'public';
  const visibility = h('fieldset', { class: 'card' },
    h('legend', {}, 'Who can see this update?'),
    visOption('regulars', 'Only my regulars', 'People who joined with your code or link.'),
    visOption('public', 'Public', scheduleIsPublic
      ? 'Also shown on your page to anyone signed in with your link.'
      : 'Shown on your page to anyone signed in with your link, once your schedule is set to “Anyone with my link”.'),
  );

  // Optional bar tag, preselected to the bar they're on at today (if any).
  const barOption = (value, title, desc) => h('label', { class: 'choice' },
    h('input', { type: 'radio', name: 'bar', value, checked: value === preselect }),
    h('span', {}, h('strong', {}, title), desc ? h('span', { class: 'help' }, desc) : null));
  const barPicker = bars.length
    ? h('fieldset', { class: 'card' },
        h('legend', {}, 'Tag a bar (optional)'),
        barOption('', 'No bar', null),
        bars.map((x) => barOption(x.id, x.name, tonightBars.has(x.id) ? 'You’re on today' : null)))
    : null;

  const submit = h('button', { type: 'submit', class: 'btn btn-primary btn-xl' }, 'Post');
  const form = h('form', { class: 'stack', novalidate: true },
    h('label', { for: 'body' }, 'What’s happening?'),
    text, counter,
    file, photoBtn, preview,
    barPicker,
    visibility,
    err,
    submit,
  );

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const body = text.value.trim();
    if (!body && !photo) { err.textContent = 'Write something or add a photo first.'; text.focus(); return; }
    submit.disabled = true; submit.textContent = 'Posting…';
    let path = null;
    try {
      if (photo) path = await uploadPhoto('post-photos', uid(), photo);
      const vis = form.querySelector('input[name=vis]:checked')?.value || 'regulars';
      const barId = form.querySelector('input[name=bar]:checked')?.value || null;
      const { error } = await supabase.from('posts').insert({ bartender_id: b.id, body, photo_path: path, visibility: vis, bar_id: barId });
      if (error) throw error;
      toast(vis === 'public' ? 'Posted publicly!' : 'Posted! Your regulars can see it now.');
      navigate('/', { replace: true });
    } catch (e2) {
      if (path) await supabase.storage.from('post-photos').remove([path]);
      submit.disabled = false; submit.textContent = 'Post';
      oops(e2, "Couldn't post. Please check your connection and try again.");
    }
  });

  return screen(backLink('#/', 'Cancel'), h('h1', {}, 'Post an update'), form);
}
