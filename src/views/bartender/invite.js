// Full-screen "Invite a regular": QR + today's sayable code + copy-link.
import QRCode from 'qrcode';
import { h, actionButton, confirmDialog } from '../../lib/dom.js';
import { supabase } from '../../supabase.js';
import { me } from '../../state.js';
import { navigate } from '../../router.js';
import { toast, oops } from '../../lib/toast.js';

export const joinUrl = (token) => `${location.origin}/#/join?t=${token}`;

export async function inviteView() {
  const { data, error } = await supabase.rpc('get_today_invite');
  if (error) throw error;

  const svg = await QRCode.toString(joinUrl(data.token), {
    type: 'svg', errorCorrectionLevel: 'M', margin: 2, color: { dark: '#1c120b', light: '#fffaf0' },
  });

  const until = new Date(data.expires_at).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
  const linkBox = h('div', { class: 'link-fallback' });

  async function copyLink() {
    linkBox.replaceChildren();
    const fetchLink = async () => {
      const res = await supabase.rpc('create_invite_link');
      if (res.error) throw res.error;
      return joinUrl(res.data.token);
    };
    let url = null;
    try {
      // ClipboardItem with a promise keeps Safari's "user gesture" alive across the network call.
      if (window.ClipboardItem && navigator.clipboard?.write) {
        const blob = fetchLink().then((u) => { url = u; return new Blob([u], { type: 'text/plain' }); });
        await navigator.clipboard.write([new ClipboardItem({ 'text/plain': blob })]);
      } else {
        url = await fetchLink();
        await navigator.clipboard.writeText(url);
      }
      toast('Invite link copied. It works for 7 days.');
    } catch (e) {
      // Clipboard blocked: show the link so it can be copied by hand.
      try {
        url = url || await fetchLink();
        const input = h('input', { type: 'text', readonly: true, value: url, 'aria-label': 'Invite link' });
        linkBox.append(h('p', { class: 'help' }, 'Press and hold to copy this link. It works for 7 days.'), input);
        input.focus(); input.select();
      } catch (e2) { oops(e2); }
    }
  }

  return h('div', { class: 'screen invite-screen' },
    h('div', { class: 'invite-top' },
      h('h1', {}, 'Invite a regular'),
      h('a', { class: 'btn btn-small btn-ghost', href: '#/', 'data-autofocus': '' }, 'Done'),
    ),
    h('p', { class: 'center lead' }, 'Have them point their phone camera here:'),
    h('div', { class: 'qr', role: 'img', 'aria-label': `QR code to follow ${me.profile.display_name}`, html: svg }),
    h('p', { class: 'center' }, 'Or they can type this code in The Usual:'),
    h('p', { class: 'invite-code', 'aria-label': `Code: ${data.code.split('-').join(', ')}` }, data.code),
    h('p', { class: 'help center' }, `Today’s code works until ${until}. You get a new one each day.`),
    actionButton('Copy invite link', copyLink, { class: 'btn btn-primary btn-xl' }),
    linkBox,
    h('p', { class: 'help center' }, 'Send the link by text, email or however you like.'),
    actionButton('Code got out? Get new codes', async () => {
      const ok = await confirmDialog({
        title: 'Get new codes?',
        body: 'Today’s code, this QR code and any links you’ve shared will stop working. People already following you are not affected.',
        confirmText: 'Yes, new codes',
      });
      if (!ok) return;
      const res = await supabase.rpc('reset_invites');
      if (res.error) return oops(res.error);
      toast('New codes ready');
      navigate('/invite', { replace: true });
    }, { class: 'btn btn-ghost btn-small' }),
  );
}
