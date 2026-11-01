// #/mod — moderator tools: report queue, suspended people, action log.
// #/mod/metrics — product metrics (aggregates only).
// Only for people in private.moderators: the router sends anyone else home, and
// every mod_* database function refuses them anyway.
import { h, screen, backLink, actionButton, confirmDialog } from '../lib/dom.js';
import { supabase } from '../supabase.js';
import { navigate } from '../router.js';
import { timeAgo, fmtDate } from '../lib/time.js';
import { photoUrls } from '../lib/images.js';
import { toast, oops } from '../lib/toast.js';
import { REPORT_REASONS } from '../lib/report.js';

const KIND = { post: 'Update', reply: 'Reply message', person: 'Person' };
const ACTION = { dismiss: 'Dismissed', remove: 'Removed', suspend: 'Suspended', unsuspend: 'Unsuspended' };
const LENGTHS = [['1', '1 day'], ['7', '7 days'], ['30', '30 days'], ['', 'Until I lift it']];

function tabs(current) {
  const tab = (href, label, key) => h('a', { class: 'tab', href, 'aria-current': current === key ? 'page' : null }, label);
  return h('nav', { class: 'tabs', 'aria-label': 'Moderator tools' },
    tab('#/mod', 'Reports', 'reports'), tab('#/mod/metrics', 'Metrics', 'metrics'));
}

const reload = () => navigate(location.hash.slice(1), { replace: true });
const fmtUntil = (iso) => (new Date(iso).getFullYear() > new Date().getFullYear() + 50 ? 'until lifted' : `until ${fmtDate(iso)}`);

// ===== #/mod — reports =====

export async function modReportsView({ query }) {
  const status = query.get('status') === 'closed' ? 'closed' : 'open';
  const [rep, sus, log] = await Promise.all([
    supabase.rpc('mod_reports', { p_status: status }),
    supabase.rpc('mod_suspended'),
    supabase.rpc('mod_log', { p_limit: 20 }),
  ]);
  if (rep.error) throw rep.error;
  const reports = rep.data || [];
  const photos = await photoUrls('post-photos', reports.map((r) => r.photo_path));

  return screen(
    backLink('#/'),
    h('h1', {}, 'Moderator tools'),
    tabs('reports'),
    h('div', { class: 'seg', role: 'group', 'aria-label': 'Which reports' },
      h('a', { class: 'btn btn-small', href: '#/mod', 'aria-current': status === 'open' ? 'true' : null }, 'Open'),
      h('a', { class: 'btn btn-small', href: '#/mod?status=closed', 'aria-current': status === 'closed' ? 'true' : null }, 'Closed')),

    reports.length
      ? h('div', { class: 'stack' }, reports.map((r) => reportCard(r, photos[r.photo_path])))
      : h('p', { class: 'card muted' }, status === 'open' ? 'No open reports. 🍻' : 'Nothing closed yet.'),

    h('section', { 'aria-labelledby': 'sus-h' },
      h('h2', { id: 'sus-h' }, 'Suspended'),
      (sus.data || []).length
        ? h('ul', { class: 'plain-list stack-tight' }, sus.data.map((s) => h('li', { class: 'card row' },
            h('span', { class: 'grow' }, h('strong', {}, s.display_name),
              h('span', { class: 'help block' }, `${fmtUntil(s.until)}${s.note ? ` · ${s.note}` : ''}`)),
            actionButton('Unsuspend', async () => {
              const ok = await confirmDialog({ title: `Unsuspend ${s.display_name}?`, body: 'They can sign in again straight away.', confirmText: 'Unsuspend', cancelText: 'Cancel' });
              if (!ok) return;
              const { error } = await supabase.rpc('mod_unsuspend', { p_user: s.user_id });
              if (error) return oops(error);
              toast(`${s.display_name} can sign in again`);
              reload();
            }, { class: 'btn btn-small btn-secondary' }))))
        : h('p', { class: 'muted' }, 'Nobody is suspended.')),

    h('section', { 'aria-labelledby': 'log-h' },
      h('h2', { id: 'log-h' }, 'Recent actions'),
      (log.data || []).length
        ? h('ul', { class: 'plain-list mod-log' }, log.data.map((a) => h('li', {},
            h('strong', {}, ACTION[a.action] || a.action), ' ', a.target_name || 'someone',
            a.note ? ` · ${a.note}` : '',
            h('span', { class: 'help block' }, `${a.moderator_name} · ${timeAgo(a.created_at)}`))))
        : h('p', { class: 'muted' }, 'No actions yet.')),
  );
}

function reportCard(r, photo) {
  const open = r.status === 'open';
  const canRemove = open && r.kind !== 'person' && r.content_live;
  const canSuspend = open && r.reported_user_id && !r.suspended_until;
  const note = h('textarea', { rows: 2, maxlength: 500, 'aria-label': 'Note for the log (optional)', placeholder: 'Note for the log (optional)' });
  const len = h('select', { 'aria-label': 'Suspend for' }, LENGTHS.map(([v, l]) => h('option', { value: v, selected: v === '7' }, l)));
  const days = () => (len.value ? Number(len.value) : null);

  async function resolve({ remove = false, suspend = false }) {
    const what = [remove && 'remove it', suspend && `suspend ${r.reported_name} (${len.selectedOptions[0].text.toLowerCase()})`].filter(Boolean).join(' and ');
    const ok = await confirmDialog({
      title: what ? `${what[0].toUpperCase()}${what.slice(1)}?` : 'Dismiss this report?',
      body: suspend ? 'They are signed out and can’t sign back in. Nobody is told why.' : remove ? 'It is deleted for everyone. The report keeps a copy.' : 'Nothing happens to anyone.',
      confirmText: what ? 'Yes, do it' : 'Dismiss', danger: !!what, cancelText: 'Cancel',
    });
    if (!ok) return;
    const { error } = await supabase.rpc('mod_resolve', {
      p_report: r.id, p_remove: remove, p_suspend: suspend, p_days: suspend ? days() : null, p_note: note.value.trim(),
    });
    if (error) return oops(error, error.message?.includes('already_resolved') ? 'Someone already handled this report.' : undefined);
    toast(what ? 'Done' : 'Report dismissed');
    reload();
  }

  return h('article', { class: 'card stack-tight report' },
    h('p', { class: 'eyebrow' }, `${KIND[r.kind]} · ${REPORT_REASONS[r.reason] || r.reason}`),
    h('p', {},
      h('strong', {}, r.reported_name), r.reported_is_bartender ? ' (bartender)' : '',
      r.reports_against > 1 ? h('span', { class: 'badge' }, `${r.reports_against} reports`) : null,
      r.suspended_until ? h('span', { class: 'badge badge-danger' }, `Suspended ${fmtUntil(r.suspended_until)}`) : null),
    h('p', { class: 'help' }, `Reported by ${r.reporter_name} · ${timeAgo(r.created_at)}`),
    r.details ? h('p', { class: 'report-details' }, `“${r.details}”`) : null,
    r.body || photo
      ? h('blockquote', { class: 'report-snapshot' },
          photo ? h('img', { src: photo, alt: 'Reported photo', loading: 'lazy' }) : null,
          r.body ? h('p', {}, r.body) : null,
          r.kind !== 'person' && !r.content_live ? h('p', { class: 'help' }, 'Already deleted. This is the copy kept with the report.') : null)
      : null,

    open
      ? h('div', { class: 'stack-tight' },
          note,
          canSuspend ? h('label', { class: 'help' }, 'If suspending: ', len) : null,
          h('div', { class: 'mod-actions' },
            canRemove ? actionButton('Remove it', () => resolve({ remove: true }), { class: 'btn btn-small btn-danger-outline' }) : null,
            canSuspend ? actionButton(`Suspend ${r.reported_name}`, () => resolve({ suspend: true }), { class: 'btn btn-small btn-danger-outline' }) : null,
            canRemove && canSuspend ? actionButton('Remove + suspend', () => resolve({ remove: true, suspend: true }), { class: 'btn btn-small btn-danger' }) : null,
            actionButton('Dismiss', () => resolve({}), { class: 'btn btn-small btn-secondary' })))
      : h('p', { class: 'help' }, h('strong', {}, r.status === 'dismissed' ? 'Dismissed' : 'Actioned'),
          r.resolution ? ` · ${r.resolution}` : '', r.resolved_at ? ` · ${timeAgo(r.resolved_at)}` : ''),
  );
}

// ===== #/mod/metrics =====

const n = (v) => Number(v || 0);
const pct = (a, b) => (n(b) ? `${Math.round((100 * n(a)) / n(b))}%` : '—');

function tile(label, value, sub) {
  return h('div', { class: 'stat' },
    h('p', { class: 'stat-label' }, label),
    h('p', { class: 'stat-value' }, String(value ?? '—')),
    sub ? h('p', { class: 'stat-sub' }, sub) : null);
}

/** Horizontal bars, one hue, each row labelled with its count and share of `total`. */
function hbars(rows, total) {
  const max = Math.max(1, ...rows.map(([, v]) => n(v)));
  return h('ul', { class: 'plain-list hbars' }, rows.map(([label, v]) => h('li', {},
    h('span', { class: 'hbar-label' }, label),
    h('span', { class: 'hbar-track', 'aria-hidden': 'true' }, h('span', { class: 'hbar-fill', style: { width: `${(100 * n(v)) / max}%` } })),
    h('span', { class: 'hbar-value' }, `${n(v)}`, total != null ? h('span', { class: 'help' }, ` ${pct(v, total)}`) : null))));
}

const SERIES = { active: 'Active people', signups: 'New people', follows: 'New follows', posts: 'Updates posted' };

/** 14-day column chart for one series, with a tap/hover readout and a table view. */
function dailyChart(daily) {
  let key = 'active';
  const wrap = h('div', { class: 'stack-tight' });
  const dayName = (d) => new Date(`${d}T12:00:00Z`).toLocaleDateString(undefined, { weekday: 'short', day: 'numeric', month: 'short', timeZone: 'UTC' });

  function draw() {
    const max = Math.max(1, ...daily.map((d) => n(d[key])));
    const total = daily.reduce((s, d) => s + n(d[key]), 0);
    const readout = h('p', { class: 'chart-readout', 'aria-live': 'polite' }, `${SERIES[key]}: ${total} in 14 days`);
    const show = (d) => { readout.textContent = `${dayName(d.day)}: ${n(d[key])} ${SERIES[key].toLowerCase()}`; };
    wrap.replaceChildren(
      h('div', { class: 'seg', role: 'group', 'aria-label': 'What to show' }, Object.entries(SERIES).map(([k, label]) =>
        h('button', { type: 'button', class: 'btn btn-small', 'aria-pressed': String(k === key), onClick: () => { key = k; draw(); } }, label))),
      readout,
      h('div', { class: 'cols', role: 'img', 'aria-label': `${SERIES[key]} per day, last 14 days` },
        daily.map((d) => h('button', {
          type: 'button', class: 'col', 'aria-label': `${dayName(d.day)}: ${n(d[key])}`,
          onPointerenter: () => show(d), onFocus: () => show(d), onClick: () => show(d),
        }, h('span', { class: 'col-fill', style: { height: `${(100 * n(d[key])) / max}%` } })))),
      h('div', { class: 'cols-axis help', 'aria-hidden': 'true' },
        h('span', {}, dayName(daily[0].day)), h('span', {}, 'Today')),
      h('details', {},
        h('summary', { class: 'help' }, 'Show as a table'),
        h('table', { class: 'data-table' },
          h('thead', {}, h('tr', {}, h('th', {}, 'Day'), Object.values(SERIES).map((l) => h('th', {}, l)))),
          h('tbody', {}, daily.map((d) => h('tr', {}, h('td', {}, dayName(d.day)), Object.keys(SERIES).map((k) => h('td', {}, n(d[k])))))))),
    );
  }
  draw();
  return wrap;
}

export async function modMetricsView() {
  const { data: m, error } = await supabase.rpc('mod_metrics');
  if (error) throw error;
  const { people, bartender_funnel: f, regulars_per_bartender: rpb, follows, posts, safety } = m;

  return screen(
    backLink('#/'),
    h('h1', {}, 'Moderator tools'),
    tabs('metrics'),

    h('div', { class: 'stats' },
      tile('People', n(people.total), `${n(people.new_7d)} new this week`),
      tile('Active this week', n(people.active_7d), `${pct(people.active_7d, people.total)} of everyone`),
      tile('Bartenders', n(people.bartenders), `${n(f.has_regular)} have a regular`),
      tile('Regulars', n(people.regulars), `follow at least one bartender`)),

    h('section', { 'aria-labelledby': 'trend-h' },
      h('h2', { id: 'trend-h' }, 'Last 14 days'),
      h('div', { class: 'card' }, dailyChart(m.daily || []))),

    h('section', { 'aria-labelledby': 'funnel-h' },
      h('h2', { id: 'funnel-h' }, 'Bartender funnel'),
      h('p', { class: 'help' }, 'Share of bartenders who reached each step.'),
      h('div', { class: 'card' }, hbars([
        ['Set up a page', f.signed_up], ['Added a shift', f.set_schedule], ['Got a regular', f.has_regular],
        ['Posted (30 days)', f.posted_30d], ['5+ regulars', f.five_regulars]], f.signed_up)),
      h('p', { class: 'help' }, `Regulars per bartender (with any): average ${rpb.avg ?? '—'}, median ${rpb.median ?? '—'}, most ${rpb.max ?? '—'}.`)),

    h('section', { 'aria-labelledby': 'follows-h' },
      h('h2', { id: 'follows-h' }, 'How regulars join (30 days)'),
      h('div', { class: 'card' }, hbars([
        ['QR code', follows.by_source_30d.qr], ['Spoken code', follows.by_source_30d.code], ['Link', follows.by_source_30d.link]], follows.new_30d)),
      h('p', { class: 'help' }, `${n(follows.new_7d)} new follows this week · ${n(follows.total)} in all.`)),

    h('section', { 'aria-labelledby': 'eng-h' },
      h('h2', { id: 'eng-h' }, 'Updates & responses (30 days)'),
      h('div', { class: 'stats' },
        tile('Updates', n(posts.new_30d), `${n(posts.new_7d)} this week`),
        tile('Got a response', pct(posts.with_response_30d, posts.new_30d), 'reaction or reply'),
        tile('Reactions', n(posts.reactions_30d), n(posts.new_30d) ? `${(n(posts.reactions_30d) / n(posts.new_30d)).toFixed(1)} per update` : null),
        tile('Replies', n(posts.replies_30d), `${pct(posts.public_30d, posts.new_30d)} of updates public`))),

    h('section', { 'aria-labelledby': 'safety-h' },
      h('h2', { id: 'safety-h' }, 'Safety'),
      h('div', { class: 'stats' },
        tile('Open reports', n(safety.reports_open), `${n(safety.reports_30d)} in 30 days`),
        tile('Blocks', n(safety.blocks_total), `${n(safety.blocks_30d)} in 30 days`),
        tile('Suspended', n(safety.suspended_now), 'right now'))),

    h('p', { class: 'help' }, '“Active” means posted, reacted, replied or followed someone. Days are UTC. ',
      `Updated ${timeAgo(m.generated_at)}.`),
  );
}
