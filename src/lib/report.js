// Report a post, a reply message or a person. Silent: the reported person is never
// told, and the reporter gets the same "thanks" whatever a moderator decides.
import { h, actionButton } from './dom.js';
import { supabase } from '../supabase.js';
import { toast, oops } from './toast.js';

export const REPORT_REASONS = {
  harassment: 'Harassment or bullying',
  safety: 'Threats or a safety worry',
  inappropriate: 'Inappropriate or offensive',
  spam: 'Spam or a scam',
  impersonation: 'Pretending to be someone else',
  other: 'Something else',
};

const WHAT = { post: 'this update', reply: 'this message', person: null };

/** Opens the report dialog. Resolves true once a report was sent. */
export function reportDialog({ kind, targetId, name }) {
  return new Promise((resolve) => {
    const what = WHAT[kind] || name;
    const err = h('p', { class: 'error', role: 'alert' });
    const details = h('textarea', { id: 'report-details', rows: 3, maxlength: 500,
      placeholder: 'Anything that helps us understand (optional)' });
    const form = h('form', { class: 'stack', noValidate: true },
      h('fieldset', { class: 'stack-tight' },
        h('legend', { class: 'help' }, 'What’s wrong?'),
        Object.entries(REPORT_REASONS).map(([value, label], i) => h('label', { class: 'choice' },
          h('input', { type: 'radio', name: 'reason', value, required: i === 0 }),
          h('span', {}, label)))),
      h('label', { for: 'report-details' }, 'More details'),
      details,
      err,
      h('button', { type: 'submit', class: 'btn btn-primary' }, 'Send report'),
      h('button', { type: 'button', class: 'btn btn-ghost', onClick: () => done(false) }, 'Cancel'),
    );
    const dlg = h('dialog', { class: 'dialog', 'aria-labelledby': 'report-title' },
      h('h2', { id: 'report-title' }, `Report ${what}`),
      h('p', { class: 'help' }, `${name} won’t be told. A moderator will look at it.`),
      form);

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      err.textContent = '';
      const reason = form.querySelector('input[name=reason]:checked')?.value;
      if (!reason) { err.textContent = 'Please choose what’s wrong.'; return; }
      const btn = form.querySelector('button[type=submit]');
      btn.disabled = true;
      const { error } = await supabase.rpc('report', {
        p_kind: kind, p_target: targetId, p_reason: reason, p_details: details.value.trim(),
      });
      btn.disabled = false;
      if (error) {
        const msg = error.message || '';
        if (msg.includes('rate_limited')) err.textContent = 'You’ve sent a lot of reports today. Please try again tomorrow.';
        else if (msg.includes('not_found')) err.textContent = 'This isn’t available any more.';
        else oops(error);
        return;
      }
      done(true);
      toast('Thanks. We’ll take a look.');
    });

    function done(v) {
      dlg.close();
      dlg.remove();
      resolve(v);
    }
    dlg.addEventListener('cancel', (e) => { e.preventDefault(); done(false); });
    document.body.append(dlg);
    dlg.showModal();
  });
}

/** A small "Report" button. onDone runs after a report is sent. */
export function reportButton(kind, targetId, name, { label = 'Report', onDone, className = 'btn btn-small btn-ghost' } = {}) {
  return actionButton(label, async () => {
    if (await reportDialog({ kind, targetId, name })) await onDone?.();
  }, { class: className });
}
