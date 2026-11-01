import { h, screen, backLink } from '../../lib/dom.js';
import { supabase } from '../../supabase.js';
import { navigate } from '../../router.js';
import { toast, oops } from '../../lib/toast.js';

const MESSAGES = {
  not_valid: 'That code didn’t work. Check the spelling, or ask for today’s code. Codes change every day.',
  too_many_tries: 'Too many tries. Please wait 10 minutes and try again.',
  self: 'That’s your own code! Give it to your regulars.',
  no_profile: 'Please finish setting up your account first.',
};

export async function enterCodeView() {
  const input = h('input', {
    id: 'code', type: 'text', autocomplete: 'off', autocapitalize: 'characters', spellcheck: 'false',
    autocorrect: 'off', maxlength: 40, class: 'code-input', placeholder: 'TIKI-MOON-42',
    'aria-describedby': 'code-help', 'data-autofocus': '',
  });
  const err = h('p', { class: 'error', role: 'alert' });
  const submit = h('button', { type: 'submit', class: 'btn btn-primary btn-xl' }, 'Connect');
  const form = h('form', { class: 'stack', noValidate: true },
    h('label', { for: 'code' }, 'Type the code your bartender gave you'),
    input,
    h('p', { id: 'code-help', class: 'help' }, 'Two words and a number. Capitals and dashes don’t matter.'),
    err, submit,
  );
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const code = input.value.trim();
    if (code.replace(/[^a-z0-9]/gi, '').length < 4) { err.textContent = 'Please type the whole code.'; input.focus(); return; }
    submit.disabled = true; submit.textContent = 'Checking…';
    const { data, error } = await supabase.rpc('redeem_invite', { p_input: code });
    submit.disabled = false; submit.textContent = 'Connect';
    if (error) return oops(error);
    if (!data.ok) { err.textContent = MESSAGES[data.reason] || MESSAGES.not_valid; input.select(); return; }
    toast(data.already ? `You already follow ${data.display_name}` : `You’re now following ${data.display_name}`);
    navigate(`/b/${data.public_id}`, { replace: true });
  });

  return screen(
    backLink('#/'),
    h('h1', {}, 'Add a bartender'),
    form,
    h('p', { class: 'help' }, 'Got a QR code instead? Just point your phone’s camera at it.'),
  );
}
