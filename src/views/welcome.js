import { h, screen } from '../lib/dom.js';
import { getPendingInvite } from '../state.js';

export function logo() {
  return h('div', { class: 'logo', 'aria-hidden': 'true' },
    h('img', { src: '/icon-192.png', alt: '', width: 72, height: 72 }));
}

export async function welcomeView() {
  const pending = getPendingInvite();
  return screen(
    h('div', { class: 'hero' },
      logo(),
      h('h1', { class: 'brand' }, 'The Usual'),
      h('p', { class: 'lead' }, 'Know where your favourite bartender is working tonight.'),
    ),
    pending ? h('p', { class: 'card note' }, 'You have an invite waiting. Sign in to accept it.') : null,
    h('a', { class: 'btn btn-primary btn-xl', href: '#/signin', 'data-autofocus': '' }, 'Get started'),
    h('ul', { class: 'plain-list reassure' },
      h('li', {}, 'Nothing to download.'),
      h('li', {}, 'Sign in with a text message code. No password.'),
      h('li', {}, 'Your phone number is never shown to anyone.'),
    ),
  );
}
