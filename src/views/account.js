// "Delete my account", shown at the bottom of both profile screens.
// Photos go first through the Storage API (Supabase blocks deleting them with SQL),
// then delete_my_account() removes the sign-in record and everything cascades (migration 0009).
import { h, actionButton, confirmDialog } from '../lib/dom.js';
import { supabase } from '../supabase.js';
import { me, uid } from '../state.js';
import { toast, oops } from '../lib/toast.js';

const BUCKETS = ['avatars', 'post-photos', 'regular-photos'];

async function removeMyPhotos() {
  const folder = uid();
  for (const bucket of BUCKETS) {
    for (;;) {
      const { data, error } = await supabase.storage.from(bucket).list(folder, { limit: 100 });
      if (error) throw error;
      const paths = (data || []).filter((f) => f.id).map((f) => `${folder}/${f.name}`);
      if (!paths.length) break;
      const { data: gone, error: rmErr } = await supabase.storage.from(bucket).remove(paths);
      if (rmErr) throw rmErr;
      if (!gone?.length) throw new Error(`could not remove photos from ${bucket}`); // never loop forever
    }
  }
}

function clearLocalData() {
  try {
    for (const k of Object.keys(localStorage)) if (k.startsWith('usual.')) localStorage.removeItem(k);
    for (const k of Object.keys(sessionStorage)) if (k.startsWith('usual.')) sessionStorage.removeItem(k);
  } catch { /* private mode */ }
}

export function deleteAccountSection() {
  const isBartender = !!me.bartender;
  const lost = isBartender
    ? 'Your page, bars, schedule, updates and photos will be deleted, and your regulars will no longer see you. Any bartenders you follow lose your profile and replies too.'
    : 'Your profile, photo, usual, birthday, reactions and replies will be deleted, and the bartenders you follow will no longer see you.';

  return h('section', { class: 'stack', 'aria-labelledby': 'delete-h' },
    h('h2', { id: 'delete-h' }, 'Delete my account'),
    h('p', { class: 'help' }, 'This removes everything you’ve added to The Usual. It can’t be undone.'),
    actionButton('Delete my account', async () => {
      const first = await confirmDialog({
        title: 'Delete your account?', body: lost,
        confirmText: 'Continue', cancelText: 'Keep my account', danger: true,
      });
      if (!first) return;
      const sure = await confirmDialog({
        title: 'Are you sure?', body: 'This is permanent. You can sign up again later with the same phone number, but you’ll start from scratch.',
        confirmText: 'Yes, delete everything', cancelText: 'Keep my account', danger: true,
      });
      if (!sure) return;
      try {
        await removeMyPhotos();
        const { error } = await supabase.rpc('delete_my_account');
        if (error) throw error;
      } catch (e) {
        return oops(e, 'Couldn’t delete your account. Please try again.');
      }
      clearLocalData();
      toast('Your account has been deleted');
      await supabase.auth.signOut({ scope: 'local' }); // SIGNED_OUT → welcome screen (main.js)
    }, { class: 'btn btn-danger-outline' }),
    h('p', { class: 'help legal-links' },
      h('a', { href: '/privacy' }, 'Privacy Policy'), ' · ', h('a', { href: '/terms' }, 'Terms'), ' · ',
      h('a', { href: 'mailto:cheers@gettheusual.bar' }, 'cheers@gettheusual.bar')),
  );
}
