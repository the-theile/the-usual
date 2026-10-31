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
  toast(message, 'error');
}
