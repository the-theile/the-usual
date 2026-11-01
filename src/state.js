// App-wide state: who is signed in and what they are.
import { supabase } from './supabase.js';

export const me = {
  session: null,
  profile: null,     // { id, display_name }
  bartender: null,   // { id, public_id, handle, bio, photo_path, timezone, schedule_visibility } or null
};

export const uid = () => me.session?.user?.id ?? null;

export async function loadMe() {
  const { data } = await supabase.auth.getSession();
  me.session = data.session;
  me.profile = null;
  me.bartender = null;
  if (!me.session) return me;
  const id = me.session.user.id;
  const [p, b] = await Promise.all([
    supabase.from('profiles').select('id, display_name').eq('id', id).maybeSingle(),
    supabase.from('bartenders').select('id, public_id, handle, handle_changed_at, bio, photo_path, timezone, schedule_visibility').eq('id', id).maybeSingle(),
  ]);
  me.profile = p.data ?? null;
  me.bartender = b.data ?? null;
  return me;
}

// Which home screen a person who is both bartender and regular sees.
const MODE_KEY = 'usual.mode';
export function getMode() {
  try { return localStorage.getItem(MODE_KEY) || 'bartender'; } catch { return 'bartender'; }
}
export function setMode(mode) {
  try { localStorage.setItem(MODE_KEY, mode); } catch { /* private mode */ }
}

// An invite token remembered across sign-in (QR scanned before having an account).
const PENDING_KEY = 'usual.pendingInvite';
export function getPendingInvite() {
  try { return sessionStorage.getItem(PENDING_KEY) || localStorage.getItem(PENDING_KEY); } catch { return null; }
}
export function setPendingInvite(token) {
  try {
    if (token) { sessionStorage.setItem(PENDING_KEY, token); localStorage.setItem(PENDING_KEY, token); }
    else { sessionStorage.removeItem(PENDING_KEY); localStorage.removeItem(PENDING_KEY); }
  } catch { /* ignore */ }
}

// Where a signed-out visitor was headed (e.g. a bartender's /tender/<handle> link),
// so sign-in and onboarding can take them there. Expires after an hour so a stale
// one never hijacks a later sign-in. Read once: takeReturnTo() clears it.
const RETURN_KEY = 'usual.returnTo';
const RETURN_TTL_MS = 60 * 60 * 1000;
export function setReturnTo(path) {
  try {
    const v = JSON.stringify({ path, at: Date.now() });
    sessionStorage.setItem(RETURN_KEY, v); localStorage.setItem(RETURN_KEY, v);
  } catch { /* private mode */ }
}
export function peekReturnTo() {
  try {
    const { path, at } = JSON.parse(sessionStorage.getItem(RETURN_KEY) || localStorage.getItem(RETURN_KEY) || 'null') || {};
    return typeof path === 'string' && path.startsWith('/') && Date.now() - at < RETURN_TTL_MS ? path : null;
  } catch { return null; }
}
export function takeReturnTo() {
  const path = peekReturnTo();
  try { sessionStorage.removeItem(RETURN_KEY); localStorage.removeItem(RETURN_KEY); } catch { /* ignore */ }
  return path;
}
