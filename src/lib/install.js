// "Add to Home Screen" tips for iPhone and Android.
// Android/Chrome can show its own install prompt; iPhone needs manual steps via the Share menu.
import { h } from './dom.js';

const DISMISS_KEY = 'usual.installTipDismissed';
let deferredPrompt = null;

// Call once at startup so we catch Chrome's install event before any screen renders.
export function initInstall() {
  window.addEventListener('beforeinstallprompt', (e) => {
    e.preventDefault(); // hold on to it; we offer it from our own button
    deferredPrompt = e;
  });
  window.addEventListener('appinstalled', () => {
    deferredPrompt = null;
    document.querySelectorAll('[data-install-tip]').forEach((el) => el.remove());
  });
}

export function isInstalled() {
  return window.matchMedia?.('(display-mode: standalone)').matches || navigator.standalone === true;
}

function platform() {
  const ua = navigator.userAgent || '';
  // iPadOS reports itself as a Mac; touch support gives it away.
  const ios = /iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1);
  if (ios) return 'ios';
  if (/Android/.test(ua)) return 'android';
  return 'other';
}

// Instagram, Facebook, Snapchat etc. open links in their own browser, which can't add to the home screen.
function inAppBrowser() {
  return /Instagram|FBAN|FBAV|FB_IAB|Snapchat|Line\/|TikTok|musical_ly/i.test(navigator.userAgent || '');
}

function steps(list) {
  return h('ol', { class: 'install-steps' }, list.map((s) => h('li', {}, s)));
}

function instructions(p) {
  if (inAppBrowser()) {
    return [
      h('p', {}, 'You’re viewing this inside another app. First open it in your phone’s browser:'),
      steps([
        'Tap the ••• or ⋮ menu in the corner.',
        p === 'ios' ? 'Choose “Open in Safari” (or “Open in browser”).' : 'Choose “Open in Chrome” (or “Open in browser”).',
        'Then come back here for the next steps.',
      ]),
    ];
  }
  if (p === 'ios') {
    return [
      steps([
        h('span', {}, 'Tap the ', h('strong', {}, 'Share'), ' button ', h('span', { 'aria-hidden': 'true' }, '⬆︎'),
          ' (a square with an arrow). In Safari it’s at the bottom; in Chrome it’s at the top.'),
        h('span', {}, 'Scroll down and tap ', h('strong', {}, 'Add to Home Screen'), '. You may need to tap “More” first.'),
        h('span', {}, 'Tap ', h('strong', {}, 'Add'), '.'),
      ]),
    ];
  }
  if (p === 'android') {
    return [
      steps([
        h('span', {}, 'Tap the ', h('strong', {}, '⋮'), ' menu at the top right of Chrome.'),
        h('span', {}, 'Tap ', h('strong', {}, 'Add to Home screen'), ' (or “Install app”).'),
        h('span', {}, 'Tap ', h('strong', {}, 'Add'), ' or ', h('strong', {}, 'Install'), '.'),
      ]),
    ];
  }
  return [
    h('p', {}, 'Open this page on your phone, then use your browser’s menu:'),
    h('ul', { class: 'install-steps' },
      h('li', {}, h('strong', {}, 'iPhone: '), 'Share ⬆︎ → Add to Home Screen'),
      h('li', {}, h('strong', {}, 'Android: '), 'Chrome menu ⋮ → Add to Home screen')),
  ];
}

async function nativeInstall() {
  if (!deferredPrompt) return false;
  const evt = deferredPrompt;
  deferredPrompt = null; // can only be used once
  evt.prompt();
  try { await evt.userChoice; } catch { /* ignore */ }
  return true;
}

function nativeButton(before) {
  return deferredPrompt
    ? h('button', { type: 'button', class: 'btn btn-primary', onClick: () => { before?.(); nativeInstall(); } }, 'Add to my home screen')
    : null;
}

/** Full instructions in a dialog. Used from the menu row. */
export function showInstallHelp() {
  const native = nativeButton(() => dlg.close());
  const dlg = h('dialog', { class: 'dialog', 'aria-labelledby': 'install-title' },
    h('h2', { id: 'install-title' }, 'Add The Usual to your home screen'),
    h('p', {}, 'Then it opens like an app, with one tap.'),
    native || instructions(platform()),
    h('div', { class: 'stack' },
      h('button', { type: 'button', class: 'btn btn-ghost', onClick: () => { dlg.close(); dlg.remove(); } }, 'Close')),
  );
  dlg.addEventListener('close', () => dlg.remove());
  document.body.append(dlg);
  dlg.showModal();
}

/** Menu row for the "More" nav. Hidden once installed. */
export function installMenuRow() {
  if (isInstalled()) return null;
  return h('button', { type: 'button', class: 'menu-row', 'data-install-tip': '', onClick: showInstallHelp },
    'Add The Usual to my home screen', h('span', { 'aria-hidden': 'true' }, '›'));
}

/** Dismissible tip card for the home screens. Only on phones, only until installed or dismissed. */
export function installTipCard() {
  const p = platform();
  if (isInstalled() || p === 'other') return null;
  try { if (localStorage.getItem(DISMISS_KEY) === '1') return null; } catch { /* private mode */ }

  return h('div', { class: 'card note stack-tight', 'data-install-tip': '' },
    h('p', { class: 'lead' }, '📲 Keep The Usual one tap away'),
    h('p', {}, 'Add it to your home screen so it opens like an app.'),
    nativeButton() || h('button', { type: 'button', class: 'btn btn-primary', onClick: showInstallHelp }, 'Show me how'),
    h('button', {
      type: 'button', class: 'btn btn-ghost',
      onClick: (e) => { try { localStorage.setItem(DISMISS_KEY, '1'); } catch { /* ignore */ } e.currentTarget.closest('.card').remove(); },
    }, 'Not now'),
  );
}
