// Hash router: #/path?query. Hash URLs keep invite tokens out of server logs.

const routes = [];

/** route('/b/:id', view, { auth: true }) */
export function route(pattern, view, opts = {}) {
  const keys = [];
  const re = new RegExp('^' + pattern.replace(/:(\w+)/g, (_, k) => { keys.push(k); return '([^/]+)'; }) + '/?$');
  routes.push({ re, keys, view, opts });
}

export function parseHash() {
  const raw = location.hash.replace(/^#/, '') || '/';
  const [path, qs = ''] = raw.split('?');
  return { path: path || '/', query: new URLSearchParams(qs) };
}

export function match(path) {
  for (const r of routes) {
    const m = r.re.exec(path);
    if (m) {
      const params = {};
      r.keys.forEach((k, i) => { params[k] = decodeURIComponent(m[i + 1]); });
      return { ...r, params };
    }
  }
  return null;
}

export function navigate(path, { replace = false } = {}) {
  const target = '#' + path;
  if (location.hash === target) {
    window.dispatchEvent(new HashChangeEvent('hashchange'));
  } else if (replace) {
    history.replaceState(null, '', target);
    window.dispatchEvent(new HashChangeEvent('hashchange'));
  } else {
    location.hash = target;
  }
}
