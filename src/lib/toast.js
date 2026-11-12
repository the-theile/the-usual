let timer;

export function toast(message, kind = 'ok') {
  const el = document.getElementById('toast');
  el.textContent = message;
  el.className = `show ${kind}`;
  clearTimeout(timer);
  timer = setTimeout(() => { el.className = ''; }, 3500);
}

export function oops(error, message = 'Something went wrong. Please try again.') {
  console.error(error);
  toast(isContentBlocked(error) ? CONTENT_BLOCKED : message, 'error');
}

// The database rejects text containing a blocked term (migration 0014).
export const CONTENT_BLOCKED = 'That includes language that isn’t allowed on The Usual. Please change it and try again.';
export function isContentBlocked(error) {
  return String(error?.message || '').includes('content_not_allowed');
}
