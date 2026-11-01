import { h, screen, clear, actionButton } from '../lib/dom.js';
import { supabase } from '../supabase.js';
import { me, uid, loadMe, getPendingInvite, setMode, takeReturnTo } from '../state.js';
import { navigate } from '../router.js';
import { oops } from '../lib/toast.js';
import { localTimezone } from '../lib/time.js';

export async function createBartenderProfile() {
  const { error } = await supabase.from('bartenders').insert({ id: uid(), timezone: localTimezone() });
  if (error && error.code !== '23505') throw error; // 23505 = already a bartender
  await loadMe();
  setMode('bartender');
}

export async function onboardingView() {
  const root = screen();
  const pending = getPendingInvite();

  function stepName() {
    clear(root);
    const input = h('input', {
      id: 'name', type: 'text', autocomplete: 'given-name', maxlength: 40, required: true,
      autocapitalize: 'words', 'data-autofocus': '', 'aria-describedby': 'name-help',
    });
    const err = h('p', { class: 'error', role: 'alert' });
    const form = h('form', { class: 'stack', noValidate: true },
      h('label', { for: 'name' }, 'What should we call you?'),
      input,
      h('p', { id: 'name-help', class: 'help' },
        'Your first name or a nickname. Only bartenders you connect with will see it.'),
      err,
      h('button', { type: 'submit', class: 'btn btn-primary btn-xl' }, 'Next'),
    );
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const name = input.value.trim();
      if (!name) { err.textContent = 'Please type a name.'; input.focus(); return; }
      const btn = form.querySelector('button');
      btn.disabled = true;
      const { error } = await supabase.from('profiles').insert({ id: uid(), display_name: name });
      btn.disabled = false;
      if (error && error.code !== '23505') { oops(error); return; }
      await loadMe();
      if (pending) {
        navigate(`/join?t=${encodeURIComponent(pending)}`, { replace: true });
      } else {
        stepRole();
      }
    });
    root.append(h('h1', {}, 'Welcome!'), form);
    queueMicrotask(() => input.focus());
  }

  function stepRole() {
    clear(root);
    root.append(
      h('h1', {}, `Nice to meet you, ${me.profile?.display_name || ''}`),
      h('p', { class: 'lead' }, 'How will you use The Usual?'),
      h('div', { class: 'stack' },
        actionButton(h('span', { class: 'two-line' }, h('strong', {}, "I'm a regular"), h('span', {}, 'I want to know where my bartenders are working')), async () => {
          setMode('regular');
          navigate(takeReturnTo() || '/', { replace: true });
        }, { class: 'btn btn-choice', 'data-autofocus': '' }),
        actionButton(h('span', { class: 'two-line' }, h('strong', {}, "I'm a bartender"), h('span', {}, 'I want my regulars to know where I am')), async () => {
          try {
            await createBartenderProfile();
            takeReturnTo(); // setting up their own page comes first; drop any saved link
            navigate('/profile?setup=1', { replace: true });
          } catch (e) { oops(e); }
        }, { class: 'btn btn-choice' }),
      ),
      h('p', { class: 'help' }, 'Bartenders can follow other bartenders too.'),
    );
  }

  if (!me.profile) stepName(); else stepRole();
  return root;
}

// "Are you a bartender? Set up your page" from the regular home screen.
export async function becomeBartenderView() {
  if (me.bartender) {
    setMode('bartender');
    navigate('/', { replace: true });
    return null;
  }
  return screen(
    h('h1', {}, 'Set up your bartender page'),
    h('p', { class: 'lead' }, "You'll get a page your regulars can follow, with your schedule and updates. You can still follow other bartenders."),
    actionButton("Yes, I'm a bartender", async () => {
      try {
        await createBartenderProfile();
        navigate('/profile?setup=1', { replace: true });
      } catch (e) { oops(e); }
    }, { class: 'btn btn-primary btn-xl', 'data-autofocus': '' }),
    h('a', { class: 'btn btn-ghost', href: '#/' }, 'Not now'),
  );
}
