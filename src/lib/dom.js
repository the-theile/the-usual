// Tiny DOM helpers. h('button', { class: 'btn', onClick }, 'Text')

export function h(tag, props, ...children) {
  const el = document.createElement(tag);
  let value;
  for (const [k, v] of Object.entries(props || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k === 'value') value = v;
    else if (k === 'style' && typeof v === 'object') Object.assign(el.style, v);
    else if (k === 'html') el.innerHTML = v; // only ever used with trusted, generated markup (QR svg)
    else if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2).toLowerCase(), v);
    else if (typeof v === 'boolean' || typeof v === 'function') el[k] = v;
    else el.setAttribute(k, v === true ? '' : String(v));
  }
  append(el, children);
  if (value !== undefined) el.value = value;
  return el;
}

export function append(el, children) {
  for (const c of children.flat(Infinity)) {
    if (c == null || c === false || c === true) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

export function clear(el) {
  while (el.firstChild) el.firstChild.remove();
  return el;
}

/** A button that shows a busy label and ignores taps while its async handler runs. */
export function actionButton(label, handler, props = {}) {
  const btn = h('button', { type: 'button', class: 'btn', ...props }, label);
  btn.addEventListener('click', async (e) => {
    if (btn.disabled) return;
    btn.disabled = true;
    btn.setAttribute('aria-busy', 'true');
    try {
      await handler(e);
    } finally {
      if (btn.isConnected) {
        btn.disabled = false;
        btn.removeAttribute('aria-busy');
      }
    }
  });
  return btn;
}

/** Big, plain confirm dialog. Resolves true/false. */
export function confirmDialog({ title, body, confirmText = 'Yes', cancelText = 'No, go back', danger = false }) {
  return new Promise((resolve) => {
    const dlg = h('dialog', { class: 'dialog', 'aria-labelledby': 'dlg-title' },
      h('h2', { id: 'dlg-title' }, title),
      body ? h('p', {}, body) : null,
      h('div', { class: 'stack' },
        h('button', { type: 'button', class: danger ? 'btn btn-danger' : 'btn btn-primary', onClick: () => done(true) }, confirmText),
        h('button', { type: 'button', class: 'btn btn-ghost', onClick: () => done(false) }, cancelText),
      ),
    );
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

export function backLink(href = '#/', label = 'Back') {
  return h('a', { class: 'back', href }, h('span', { 'aria-hidden': 'true' }, '‹ '), label);
}

export function screen(...children) {
  return h('div', { class: 'screen' }, ...children);
}
