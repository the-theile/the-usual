import { h, screen, backLink, actionButton, confirmDialog } from '../../lib/dom.js';
import { supabase } from '../../supabase.js';
import { navigate } from '../../router.js';
import { fmtDate } from '../../lib/time.js';
import { toast, oops } from '../../lib/toast.js';

export async function regularsView() {
  const { data, error } = await supabase.rpc('my_regulars');
  if (error) throw error;
  const regulars = data.filter((r) => !r.blocked);
  const blocked = data.filter((r) => r.blocked);
  const reload = () => navigate('/regulars', { replace: true });

  return screen(
    backLink('#/'),
    h('h1', {}, 'My regulars'),
    h('p', { class: 'lead' }, regulars.length === 1 ? '1 person follows you.' : `${regulars.length} people follow you.`),

    regulars.length === 0
      ? h('div', { class: 'card note' },
          h('p', {}, 'No regulars yet. Show your QR code or say today’s code to your first one.'),
          h('a', { class: 'btn btn-primary', href: '#/invite' }, 'Invite a regular'))
      : h('ul', { class: 'plain-list stack-tight' }, regulars.map((r) => h('li', { class: 'card row' },
          h('span', {}, h('strong', {}, r.display_name), h('span', { class: 'help block' }, `Since ${fmtDate(r.since)}`)),
          actionButton('Block', async () => {
            const ok = await confirmDialog({
              title: `Block ${r.display_name}?`,
              body: `${r.display_name} won’t be told. They’ll stop seeing your updates, schedule and profile, and your codes and links won’t work for them.`,
              confirmText: `Block ${r.display_name}`, danger: true, cancelText: 'Cancel',
            });
            if (!ok) return;
            const res = await supabase.rpc('block_regular', { p_regular: r.regular_id });
            if (res.error) return oops(res.error);
            toast(`${r.display_name} is blocked`);
            reload();
          }, { class: 'btn btn-small btn-danger-outline' })))),

    blocked.length
      ? h('section', { 'aria-labelledby': 'blocked-h' },
          h('h2', { id: 'blocked-h' }, 'Blocked'),
          h('p', { class: 'help' }, 'Only you can see this list.'),
          h('ul', { class: 'plain-list stack-tight' }, blocked.map((r) => h('li', { class: 'card row' },
            h('span', {}, h('strong', {}, r.display_name), h('span', { class: 'help block' }, `Blocked ${fmtDate(r.since)}`)),
            actionButton('Unblock', async () => {
              const ok = await confirmDialog({
                title: `Unblock ${r.display_name}?`,
                body: 'They won’t be reconnected. They’d need a new code or link from you to follow you again.',
                confirmText: 'Unblock', cancelText: 'Cancel',
              });
              if (!ok) return;
              const res = await supabase.rpc('unblock_regular', { p_regular: r.regular_id });
              if (res.error) return oops(res.error);
              toast(`${r.display_name} is unblocked`);
              reload();
            }, { class: 'btn btn-small btn-ghost' })))))
      : null,
  );
}
