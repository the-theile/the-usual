import { h, screen, backLink, actionButton, confirmDialog } from '../../lib/dom.js';
import { supabase } from '../../supabase.js';
import { me } from '../../state.js';
import { navigate } from '../../router.js';
import { barDay, addDays, dayLabel, fmtShift, fmtWeekdays, WEEKDAYS, isoWeekday } from '../../lib/time.js';
import { toast, oops } from '../../lib/toast.js';

const DAYS_AHEAD = 14;

export async function loadBars() {
  const { data, error } = await supabase.from('bars').select('id, name, area')
    .eq('bartender_id', me.bartender.id).order('sort').order('created_at');
  if (error) throw error;
  return data;
}

// ===== Main schedule screen =====

export async function scheduleView() {
  const b = me.bartender;
  const today = barDay(b.timezone);
  const until = addDays(today, DAYS_AHEAD - 1);

  const [bars, patternsRes, occRes, excRes] = await Promise.all([
    loadBars(),
    supabase.from('shift_patterns').select('id, bar_id, weekdays, start_time, end_time, note, starts_on, ends_on')
      .eq('bartender_id', b.id).order('created_at'),
    supabase.rpc('get_schedule', { p_bartenders: [b.id], p_from: today, p_to: until }),
    supabase.from('shift_exceptions').select('pattern_id, occurrence_date, cancelled')
      .eq('bartender_id', b.id).gte('occurrence_date', today).lte('occurrence_date', until),
  ]);
  if (patternsRes.error) throw patternsRes.error;
  if (occRes.error) throw occRes.error;
  const barName = Object.fromEntries(bars.map((x) => [x.id, x.name]));
  const patterns = (patternsRes.data || []).filter((p) => !p.ends_on || p.ends_on >= today);
  const changed = new Set((excRes.data || []).filter((e) => !e.cancelled).map((e) => `${e.pattern_id}|${e.occurrence_date}`));

  // Group occurrences by date
  const byDate = new Map();
  for (const o of occRes.data || []) {
    if (!byDate.has(o.occurrence_date)) byDate.set(o.occurrence_date, []);
    byDate.get(o.occurrence_date).push(o);
  }

  return screen(
    backLink('#/'),
    h('h1', {}, 'My schedule'),

    visibilitySection(),

    bars.length === 0
      ? h('div', { class: 'card note' },
          h('p', {}, 'First, add the bar (or bars) where you work.'),
          h('a', { class: 'btn btn-primary', href: '#/profile' }, 'Add my bars'))
      : h('div', { class: 'stack' },
          h('a', { class: 'btn btn-primary btn-xl', href: '#/schedule/weekly/new', 'data-autofocus': '' }, 'Add a weekly shift'),
          h('a', { class: 'btn btn-secondary', href: '#/schedule/once/new' }, 'Add a one-off shift')),

    h('section', { 'aria-labelledby': 'next' },
      h('h2', { id: 'next' }, 'Next two weeks'),
      byDate.size === 0
        ? h('p', { class: 'muted' }, 'No shifts yet.')
        : [...byDate.entries()].map(([date, list]) => h('div', { class: 'day-group' },
            h('h3', { class: 'day-label' }, dayLabel(date, today)),
            list.map((o) => occurrenceRow(o, changed.has(`${o.source_id}|${o.occurrence_date}`))))),
    ),

    h('section', { 'aria-labelledby': 'weekly' },
      h('h2', { id: 'weekly' }, 'Weekly shifts'),
      patterns.length === 0
        ? h('p', { class: 'muted' }, 'None yet. A weekly shift repeats on the days you pick.')
        : patterns.map((p) => h('a', { class: 'card row-link', href: `#/schedule/weekly/${p.id}` },
            h('span', {},
              h('strong', {}, fmtWeekdays(p.weekdays)),
              h('br'),
              `${barName[p.bar_id] || 'Bar'} · ${fmtShift(p.start_time, p.end_time)}`,
              p.note ? h('span', { class: 'muted' }, ` · ${p.note}`) : null),
            h('span', { class: 'chev', 'aria-hidden': 'true' }, 'Edit ›'))),
    ),
  );
}

function visibilitySection() {
  const b = me.bartender;
  const linkWrap = h('div');
  const renderLink = () => {
    linkWrap.replaceChildren();
    if (me.bartender.schedule_visibility !== 'public') return;
    linkWrap.append(actionButton('Copy my schedule page link', async () => {
      const url = `${location.origin}/#/b/${b.public_id}`;
      try { await navigator.clipboard.writeText(url); toast('Link copied'); }
      catch { linkWrap.append(h('input', { type: 'text', readonly: true, value: url, 'aria-label': 'Schedule page link' })); }
    }, { class: 'btn btn-ghost btn-small' }));
  };

  const option = (value, title, desc) => {
    const input = h('input', { type: 'radio', name: 'vis', value, checked: b.schedule_visibility === value });
    input.addEventListener('change', async () => {
      const { error } = await supabase.from('bartenders').update({ schedule_visibility: value }).eq('id', b.id);
      if (error) return oops(error);
      me.bartender.schedule_visibility = value;
      toast(value === 'public' ? 'Your schedule is now public' : 'Only your regulars can see your schedule');
      renderLink();
    });
    return h('label', { class: 'choice' }, input, h('span', {}, h('strong', {}, title), h('span', { class: 'help' }, desc)));
  };

  renderLink();
  return h('fieldset', { class: 'card' },
    h('legend', {}, 'Who can see my schedule?'),
    option('regulars', 'Only my regulars', 'People who joined with your code or link.'),
    option('public', 'Anyone with my link', 'Any signed-in person with your page link. They also see updates you mark Public.'),
    linkWrap,
  );
}

function occurrenceRow(o, isChanged) {
  const actions = h('div', { class: 'row-actions', hidden: true });
  const toggle = h('button', { type: 'button', class: `card occ ${o.cancelled ? 'cancelled' : ''}`, 'aria-expanded': 'false' },
    h('span', {},
      h('strong', {}, o.bar_name), ' · ', fmtShift(o.start_time, o.end_time),
      o.note ? h('span', { class: 'muted' }, ` · ${o.note}`) : null,
      o.cancelled ? h('span', { class: 'badge' }, 'Cancelled') : null,
      isChanged ? h('span', { class: 'badge' }, 'Changed') : null,
      o.source === 'pattern' ? h('span', { class: 'help block' }, 'Weekly shift') : null),
    h('span', { class: 'chev', 'aria-hidden': 'true' }, 'Options'),
  );
  toggle.addEventListener('click', () => {
    actions.hidden = !actions.hidden;
    toggle.setAttribute('aria-expanded', String(!actions.hidden));
  });

  const reload = () => navigate('/schedule', { replace: true });

  if (o.source === 'pattern') {
    if (o.cancelled) {
      actions.append(actionButton('Bring this night back', async () => {
        const { error } = await supabase.from('shift_exceptions').delete()
          .eq('pattern_id', o.source_id).eq('occurrence_date', o.occurrence_date);
        if (error) return oops(error);
        toast('Shift is back on'); reload();
      }, { class: 'btn btn-secondary' }));
    } else {
      actions.append(
        h('a', { class: 'btn btn-secondary', href: `#/schedule/night/${o.source_id}/${o.occurrence_date}` }, 'Change this night only'),
        actionButton('Cancel this night only', async () => {
          const ok = await confirmDialog({ title: 'Cancel this night?', body: 'Your regulars will see you’re off. Other weeks stay the same.', confirmText: 'Cancel this night', cancelText: 'Keep it' });
          if (!ok) return;
          const { error } = await supabase.from('shift_exceptions').upsert({
            pattern_id: o.source_id, bartender_id: me.bartender.id, occurrence_date: o.occurrence_date,
            cancelled: true, bar_id: null, start_time: null, end_time: null, note: '',
          }, { onConflict: 'pattern_id,occurrence_date' });
          if (error) return oops(error);
          toast('Night cancelled'); reload();
        }, { class: 'btn btn-danger-outline' }),
      );
      if (isChanged) {
        actions.append(actionButton('Undo my change', async () => {
          const { error } = await supabase.from('shift_exceptions').delete()
            .eq('pattern_id', o.source_id).eq('occurrence_date', o.occurrence_date);
          if (error) return oops(error);
          toast('Back to the usual times'); reload();
        }, { class: 'btn btn-ghost' }));
      }
    }
  } else {
    actions.append(
      h('a', { class: 'btn btn-secondary', href: `#/schedule/once/${o.source_id}` }, 'Change'),
      actionButton('Delete this shift', async () => {
        const ok = await confirmDialog({ title: 'Delete this shift?', confirmText: 'Delete', danger: true, cancelText: 'Keep it' });
        if (!ok) return;
        const { error } = await supabase.from('shifts').delete().eq('id', o.source_id);
        if (error) return oops(error);
        toast('Shift deleted'); reload();
      }, { class: 'btn btn-danger-outline' }),
    );
  }
  return h('div', { class: 'occ-wrap' }, toggle, actions);
}

// ===== Shared form fields =====

function barPicker(bars, selected) {
  const sel = selected || bars[0]?.id;
  return h('fieldset', { class: 'stack-tight' },
    h('legend', {}, 'Where?'),
    bars.map((b) => h('label', { class: 'choice' },
      h('input', { type: 'radio', name: 'bar', value: b.id, checked: b.id === sel, required: true }),
      h('span', {}, h('strong', {}, b.name), b.area ? h('span', { class: 'help' }, b.area) : null))),
    h('a', { class: 'help-link', href: '#/profile' }, 'Add another bar'),
  );
}

function timeFields(start = '18:00', end = null) {
  const startInput = h('input', { id: 'start', type: 'time', step: 900, value: start.slice(0, 5), required: true });
  const closeBox = h('input', { id: 'until-close', type: 'checkbox', checked: !end });
  const endInput = h('input', { id: 'end', type: 'time', step: 900, value: (end || '23:00').slice(0, 5) });
  const endWrap = h('div', { class: 'stack-tight', hidden: !end }, h('label', { for: 'end' }, 'Finishes at'), endInput);
  closeBox.addEventListener('change', () => { endWrap.hidden = closeBox.checked; });
  const node = h('div', { class: 'stack' },
    h('div', { class: 'stack-tight' }, h('label', { for: 'start' }, 'Starts at'), startInput),
    h('label', { class: 'check' }, closeBox, h('span', {}, 'Until close')),
    endWrap,
  );
  return {
    node,
    read: () => ({ start_time: startInput.value, end_time: closeBox.checked ? null : endInput.value || null }),
  };
}

function noteField(value = '') {
  const input = h('input', { id: 'note', type: 'text', maxlength: 80, value, placeholder: 'e.g. Trivia night' });
  return { node: h('div', { class: 'stack-tight' }, h('label', { for: 'note' }, 'Note (optional)'), input), read: () => input.value.trim() };
}

function readBar(form) {
  return form.querySelector('input[name=bar]:checked')?.value || null;
}

async function needBars() {
  const bars = await loadBars();
  if (bars.length) return { bars };
  return {
    view: screen(backLink('#/schedule'), h('h1', {}, 'Add your bar first'),
      h('p', {}, 'Tell us where you work, then come back to add shifts.'),
      h('a', { class: 'btn btn-primary btn-xl', href: '#/profile' }, 'Add my bars')),
  };
}

// ===== Weekly (repeating) shift =====

export async function weeklyFormView({ params }) {
  const { bars, view } = await needBars();
  if (view) return view;
  let p = null;
  if (params.id) {
    const { data, error } = await supabase.from('shift_patterns').select('*').eq('id', params.id).maybeSingle();
    if (error) throw error;
    p = data;
  }
  const days = new Set(p?.weekdays || []);
  const dayBoxes = WEEKDAYS.map((d) => {
    const input = h('input', { type: 'checkbox', name: 'day', value: d.n, checked: days.has(d.n) });
    return h('label', { class: 'day-toggle' }, input, h('span', {}, d.short));
  });
  const times = timeFields(p?.start_time, p ? p.end_time : null);
  const note = noteField(p?.note);
  const err = h('p', { class: 'error', role: 'alert' });

  const form = h('form', { class: 'stack', novalidate: true },
    barPicker(bars, p?.bar_id),
    h('fieldset', {}, h('legend', {}, 'Which days?'), h('div', { class: 'day-grid' }, dayBoxes)),
    times.node, note.node, err,
    h('button', { type: 'submit', class: 'btn btn-primary btn-xl' }, p ? 'Save changes' : 'Save weekly shift'),
  );

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const weekdays = [...form.querySelectorAll('input[name=day]:checked')].map((i) => Number(i.value));
    const bar_id = readBar(form);
    const t = times.read();
    if (!bar_id) { err.textContent = 'Pick a bar.'; return; }
    if (!weekdays.length) { err.textContent = 'Pick at least one day.'; return; }
    if (!t.start_time) { err.textContent = 'Pick a start time.'; return; }
    const row = { bar_id, weekdays, ...t, note: note.read() };
    const btn = form.querySelector('button[type=submit]');
    btn.disabled = true;
    const res = p
      ? await supabase.from('shift_patterns').update(row).eq('id', p.id)
      : await supabase.from('shift_patterns').insert({ ...row, bartender_id: me.bartender.id, starts_on: barDay(me.bartender.timezone) });
    btn.disabled = false;
    if (res.error) return oops(res.error);
    toast('Schedule saved');
    navigate('/schedule', { replace: true });
  });

  return screen(
    backLink('#/schedule', 'Cancel'),
    h('h1', {}, p ? 'Change weekly shift' : 'Add a weekly shift'),
    p ? h('p', { class: 'help' }, 'Changes apply to every week. To change just one night, use “Options” on that night instead.') : null,
    form,
    p ? actionButton('Stop this weekly shift', async () => {
      const ok = await confirmDialog({ title: 'Stop this weekly shift?', body: 'It will be removed from your schedule from today on.', confirmText: 'Stop it', danger: true, cancelText: 'Keep it' });
      if (!ok) return;
      const { error } = await supabase.from('shift_patterns').delete().eq('id', p.id);
      if (error) return oops(error);
      toast('Weekly shift removed');
      navigate('/schedule', { replace: true });
    }, { class: 'btn btn-danger-outline' }) : null,
  );
}

// ===== One-off shift =====

export async function onceFormView({ params }) {
  const { bars, view } = await needBars();
  if (view) return view;
  let s = null;
  if (params.id) {
    const { data, error } = await supabase.from('shifts').select('*').eq('id', params.id).maybeSingle();
    if (error) throw error;
    s = data;
  }
  const today = barDay(me.bartender.timezone);
  const date = h('input', { id: 'date', type: 'date', min: today, value: s?.shift_date || today, required: true });
  const times = timeFields(s?.start_time, s ? s.end_time : null);
  const note = noteField(s?.note);
  const err = h('p', { class: 'error', role: 'alert' });

  const form = h('form', { class: 'stack', novalidate: true },
    barPicker(bars, s?.bar_id),
    h('div', { class: 'stack-tight' }, h('label', { for: 'date' }, 'Which day?'), date),
    times.node, note.node, err,
    h('button', { type: 'submit', class: 'btn btn-primary btn-xl' }, s ? 'Save changes' : 'Save shift'),
  );
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const bar_id = readBar(form);
    const t = times.read();
    if (!bar_id) { err.textContent = 'Pick a bar.'; return; }
    if (!date.value) { err.textContent = 'Pick a day.'; return; }
    if (!t.start_time) { err.textContent = 'Pick a start time.'; return; }
    const row = { bar_id, shift_date: date.value, ...t, note: note.read() };
    const res = s
      ? await supabase.from('shifts').update(row).eq('id', s.id)
      : await supabase.from('shifts').insert({ ...row, bartender_id: me.bartender.id });
    if (res.error) return oops(res.error);
    toast('Shift saved');
    navigate('/schedule', { replace: true });
  });

  return screen(backLink('#/schedule', 'Cancel'), h('h1', {}, s ? 'Change shift' : 'Add a one-off shift'), form);
}

// ===== Change a single night of a weekly shift =====

export async function nightFormView({ params }) {
  const { patternId, date: day } = params;
  const [bars, pRes, eRes] = await Promise.all([
    loadBars(),
    supabase.from('shift_patterns').select('*').eq('id', patternId).maybeSingle(),
    supabase.from('shift_exceptions').select('*').eq('pattern_id', patternId).eq('occurrence_date', day).maybeSingle(),
  ]);
  const p = pRes.data;
  if (!p || !/^\d{4}-\d{2}-\d{2}$/.test(day) || !p.weekdays.includes(isoWeekday(day))) {
    navigate('/schedule', { replace: true });
    return null;
  }
  const ex = eRes.data && !eRes.data.cancelled ? eRes.data : null;
  const cur = ex || p;
  const times = timeFields(cur.start_time, cur.end_time);
  const note = noteField(cur.note);
  const err = h('p', { class: 'error', role: 'alert' });
  const today = barDay(me.bartender.timezone);

  const form = h('form', { class: 'stack', novalidate: true },
    barPicker(bars, cur.bar_id),
    times.node, note.node, err,
    h('button', { type: 'submit', class: 'btn btn-primary btn-xl' }, 'Save this night'),
  );
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const bar_id = readBar(form);
    const t = times.read();
    if (!bar_id || !t.start_time) { err.textContent = 'Pick a bar and a start time.'; return; }
    const { error } = await supabase.from('shift_exceptions').upsert({
      pattern_id: p.id, bartender_id: me.bartender.id, occurrence_date: day,
      cancelled: false, bar_id, ...t, note: note.read(),
    }, { onConflict: 'pattern_id,occurrence_date' });
    if (error) return oops(error);
    toast('Saved for this night only');
    navigate('/schedule', { replace: true });
  });

  return screen(
    backLink('#/schedule', 'Cancel'),
    h('h1', {}, `Change ${dayLabel(day, today) === 'Tonight' ? 'tonight' : dayLabel(day, today)}`),
    h('p', { class: 'help' }, 'Only this night changes. Your other weeks stay the same.'),
    form,
  );
}

