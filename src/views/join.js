// #/join?t=TOKEN — where the QR code and invite links land.
import { h, screen } from '../lib/dom.js';
import { supabase } from '../supabase.js';
import { me, setPendingInvite } from '../state.js';
import { navigate } from '../router.js';
import { logo } from './welcome.js';

export async function joinView({ query }) {
  const token = (query.get('t') || '').trim().toLowerCase();

  if (!/^[0-9a-f]{32}$/.test(token)) return expired();

  // Not signed in yet: show who invited them, remember the token, then sign in.
  if (!me.session) {
    const { data } = await supabase.rpc('preview_invite', { p_token: token });
    if (!data?.ok) return expired();
    setPendingInvite(token);
    return screen(
      h('div', { class: 'hero' },
        logo(),
        h('h1', {}, `${data.display_name} invited you`),
        h('p', { class: 'lead' }, `Follow ${data.display_name} on The Usual to see where they're working and what's on tonight.`),
      ),
      h('a', { class: 'btn btn-primary btn-xl', href: '#/signin', 'data-autofocus': '' }, 'Accept invite'),
      h('p', { class: 'help center' }, "You'll sign in with your phone number. It stays private."),
    );
  }

  if (!me.profile) {
    setPendingInvite(token);
    navigate('/onboarding', { replace: true });
    return null;
  }

  // Signed in: connect instantly.
  const { data, error } = await supabase.rpc('redeem_invite', { p_input: token });
  setPendingInvite(null);
  if (error) throw error;
  if (data?.reason === 'self') {
    return screen(h('h1', {}, "That's your own invite"), h('p', {}, 'Share it with your regulars so they can follow you.'),
      h('a', { class: 'btn btn-primary btn-xl', href: '#/' }, 'Go to my home screen'));
  }
  if (data?.reason === 'too_many_tries') {
    return screen(h('h1', {}, 'Please wait a little'), h('p', {}, 'There have been too many tries. Wait a few minutes, then open the invite again.'),
      h('a', { class: 'btn btn-primary btn-xl', href: '#/' }, 'Go to my home screen'));
  }
  if (!data?.ok) return expired();

  return screen(
    h('div', { class: 'hero' },
      h('p', { class: 'big-emoji', 'aria-hidden': 'true' }, '🍻'),
      h('h1', {}, data.already ? `You already follow ${data.display_name}` : `You're connected with ${data.display_name}`),
      h('p', { class: 'lead' }, `You'll see where ${data.display_name} is working and their latest updates on your home screen.`),
    ),
    h('a', { class: 'btn btn-primary btn-xl', href: `#/b/${data.public_id}`, 'data-autofocus': '' }, `See ${data.display_name}'s page`),
    h('a', { class: 'btn btn-ghost', href: '#/' }, 'Go to my home screen'),
  );
}

function expired() {
  setPendingInvite(null);
  return screen(
    h('h1', {}, 'This invite has run out'),
    h('p', { class: 'lead' }, 'Invites only last a short while. Ask your bartender for a new one, or type in today\'s code.'),
    me.session && me.profile
      ? h('a', { class: 'btn btn-primary btn-xl', href: '#/code', 'data-autofocus': '' }, 'Type a code')
      : h('a', { class: 'btn btn-primary btn-xl', href: '#/signin', 'data-autofocus': '' }, 'Sign in'),
    h('a', { class: 'btn btn-ghost', href: '#/' }, 'Go to the home screen'),
  );
}
