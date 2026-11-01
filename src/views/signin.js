import { h, screen, backLink, clear } from '../lib/dom.js';
import { supabase } from '../supabase.js';
import { loadMe, me, getPendingInvite, takeReturnTo } from '../state.js';
import { navigate } from '../router.js';
import { oops } from '../lib/toast.js';

/** Accepts "(555) 123-4567", "555 123 4567", "+44 7700 900123". Assumes US/Canada without a +. */
export function toE164(input) {
  const raw = String(input || '').trim();
  const digits = raw.replace(/\D/g, '');
  if (raw.startsWith('+')) return digits.length >= 8 && digits.length <= 15 ? `+${digits}` : null;
  if (digits.length === 10) return `+1${digits}`;
  if (digits.length === 11 && digits.startsWith('1')) return `+${digits}`;
  return null;
}

function maskPhone(e164) {
  return `the number ending in ${e164.slice(-4)}`;
}

// Opens in a new tab so the sign-in flow isn't lost.
const legalLink = (href, text) => h('a', { href, target: '_blank', rel: 'noopener' }, text);

export async function signinView() {
  const root = screen();
  let phone = '';
  let resendAt = 0;

  function stepPhone(errorText) {
    clear(root);
    const input = h('input', {
      id: 'phone', type: 'tel', inputmode: 'tel', autocomplete: 'tel', required: true,
      placeholder: '(555) 123-4567', value: phone, 'data-autofocus': '',
      'aria-describedby': 'phone-help',
    });
    const err = h('p', { class: 'error', role: 'alert' }, errorText || '');
    const form = h('form', { class: 'stack', noValidate: true },
      h('label', { for: 'phone' }, 'Your mobile number'),
      input,
      h('p', { id: 'phone-help', class: 'help' },
        "We'll text you a 6-digit code. Nobody else ever sees your number. Outside the US or Canada? Start with + and your country code."),
      err,
      h('button', { type: 'submit', class: 'btn btn-primary btn-xl' }, 'Text me a code'),
      h('p', { class: 'help' },
        'By tapping “Text me a code” you agree to our ', legalLink('/terms', 'Terms'), ' and ',
        legalLink('/privacy', 'Privacy Policy'), ', and to get a one-time sign-in code by text. Message and data rates may apply.'),
    );
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const e164 = toE164(input.value);
      if (!e164) { err.textContent = 'Please check the number. It should look like (555) 123-4567.'; input.focus(); return; }
      phone = e164;
      const btn = form.querySelector('button[type=submit]');
      btn.disabled = true; btn.textContent = 'Sending…';
      const { error } = await supabase.auth.signInWithOtp({ phone });
      btn.disabled = false; btn.textContent = 'Text me a code';
      if (error) {
        console.error(error);
        err.textContent = error.status === 429
          ? 'Too many codes requested. Please wait a minute and try again.'
          : "We couldn't send a text to that number. Please check it and try again.";
        return;
      }
      resendAt = Date.now() + 30_000;
      stepCode();
    });
    root.append(backLink('#/welcome'), h('h1', {}, 'Sign in'), form);
    queueMicrotask(() => input.focus());
  }

  function stepCode() {
    clear(root);
    const input = h('input', {
      id: 'otp', type: 'text', inputmode: 'numeric', autocomplete: 'one-time-code', pattern: '[0-9]*',
      maxlength: 6, class: 'otp', 'aria-describedby': 'otp-help', 'data-autofocus': '',
    });
    const err = h('p', { class: 'error', role: 'alert' });
    const submit = h('button', { type: 'submit', class: 'btn btn-primary btn-xl' }, 'Sign in');
    const form = h('form', { class: 'stack', noValidate: true },
      h('label', { for: 'otp' }, 'Enter the 6-digit code'),
      h('p', { id: 'otp-help', class: 'help' }, `We texted it to ${maskPhone(phone)}.`),
      input, err, submit,
    );
    let busy = false;
    async function verify() {
      const token = input.value.replace(/\D/g, '');
      if (token.length !== 6 || busy) { if (!busy) err.textContent = 'The code has 6 numbers.'; return; }
      busy = true; submit.disabled = true; submit.textContent = 'Checking…';
      const { error } = await supabase.auth.verifyOtp({ phone, token, type: 'sms' });
      busy = false; submit.disabled = false; submit.textContent = 'Sign in';
      if (error) {
        console.error(error);
        err.textContent = "That code didn't work. Check it, or send a new one.";
        input.select();
        return;
      }
      try {
        await loadMe();
      } catch (e2) { oops(e2); }
      const pending = getPendingInvite();
      if (!me.profile) navigate('/onboarding', { replace: true });
      else if (pending) navigate(`/join?t=${encodeURIComponent(pending)}`, { replace: true });
      else navigate(takeReturnTo() || '/', { replace: true });
    }
    input.addEventListener('input', () => {
      input.value = input.value.replace(/\D/g, '').slice(0, 6);
      if (input.value.length === 6) verify();
    });
    form.addEventListener('submit', (e) => { e.preventDefault(); verify(); });

    const resend = h('button', { type: 'button', class: 'btn btn-ghost' }, 'Send a new code');
    resend.addEventListener('click', async () => {
      const wait = Math.ceil((resendAt - Date.now()) / 1000);
      if (wait > 0) { err.textContent = `Please wait ${wait} seconds before asking for a new code.`; return; }
      resend.disabled = true;
      const { error } = await supabase.auth.signInWithOtp({ phone });
      resend.disabled = false;
      if (error) { err.textContent = 'Could not send a new code. Please try again in a minute.'; return; }
      resendAt = Date.now() + 30_000;
      err.textContent = '';
      input.value = '';
      input.focus();
    });

    root.append(
      h('h1', {}, 'Check your texts'),
      form,
      h('div', { class: 'stack' },
        resend,
        h('button', { type: 'button', class: 'btn btn-ghost', onClick: () => stepPhone() }, 'Use a different number')),
    );
    queueMicrotask(() => input.focus());
  }

  stepPhone();
  return root;
}
