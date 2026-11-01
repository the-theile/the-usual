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
    h('h2', {}, 'How it works'),
    h('p', { class: 'muted' },
      h('strong', {}, 'Bartenders: '),
      'add the bars you work at and your shifts, then invite your regulars with a QR code, a spoken code or a link. Share posts with just your regulars or with anyone who has your link.'),
    h('p', { class: 'muted' },
      h('strong', {}, 'Regulars: '),
      'scan the code or open the link your bartender gives you. Your home screen shows who\'s working tonight and where, plus their latest posts.'),
    h('p', { class: 'help legal-links' },
      h('a', { href: '/privacy' }, 'Privacy'), ' · ', h('a', { href: '/terms' }, 'Terms'), ' · ',
      h('a', { href: 'mailto:cheers@gettheusual.bar' }, 'Contact')),
  );
}
