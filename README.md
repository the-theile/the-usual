# The Usual

Bartenders tell their regulars where they're working, without sharing a phone number or social media.

A mobile-first web app built with plain JavaScript and Vite, with Supabase for sign-in, the database and photos. There is no UI framework.

## What's in Version 1

- Sign-in with a phone number and a one-time SMS code. Phone numbers are never shown to anyone.
- **Bartenders:** photo, name, bio, the bars they work at.
- **Invite a regular:** a QR code, today's spoken code (e.g. `TIKI-MOON-42`, changes at 5am local time) and a copy-able link that lasts 7 days. All three connect the regular instantly.
- **Posts:** text with an optional photo. Photos are resized and re-encoded in the browser, which also removes GPS/EXIF data. Each post is "Only my regulars" (the default) or "Public", and the bartender can switch it later. Public posts show on the bartender's page to non-regulars while the schedule is set to "Anyone with my link". Viewers must be signed in, and blocked people never see them. Non-regulars can read a public post and see its reaction counts, but only regulars can react or reply.
- **Pinned update:** a bartender can pin one update. It stays at the top of their page, and its first line shows on their card on the regular home screen, until they pin another, unpin it or delete it. Who can see it is unchanged.
- **I'm coming tonight:** on a night their bartender is working, a regular can tap "I'm coming tonight" (and take it back). The bartender's home lists who's coming, with faces and usual drinks. Other regulars only see a count ("3 others are coming"), never names. It resets at 5am.
- **Schedule:** one-off shifts, weekly shifts, and changing or cancelling a single night.
- **Schedule privacy:** "Only my regulars" or "Anyone with my link" (signed-in users only).
- **Regular home:** who's working tonight, then recent posts.
- **Reactions & replies:** regulars react to a post (🍻 ❤️ 😂 🔥 👀 👏, one each) and can reply privately. Regulars see reaction counts only; the bartender sees who reacted. Each reply is a private conversation between that regular and the bartender, who can answer (20 messages max per conversation). Senders can edit or delete their own messages. Reacting and replying close 7 days after a post. The bartender's home shows a "new" badge.
- **Regular profiles:** regulars can add a photo, "my usual" (their go-to drink) and a birthday (month + day, no year) on **My profile**. Only the bartenders they follow can see these, plus a bartender who blocked them. Other regulars never do, and neither do a bartender-regular's own regulars. The regular home suggests setting this up once they follow someone.
- **For bartenders:** My regulars shows each regular's photo and usual. Tapping a regular opens their page, where the bartender can keep a **private note** (only that bartender ever sees it). Their home shows **birthdays this week**, and the reactions & replies screen shows faces and usual drinks.
- **Delete my account:** at the bottom of My profile (or My profile & bars for bartenders). It removes the person's photos, then everything else they added, and signs them out. It can't be undone.
- **Silent blocking,** enforced in the database (RLS): the blocked person loses posts, schedule, profile and photos, and codes and links stop working for them. They are never told.

## Project layout

```
index.html                 app shell
src/main.js                routes and rendering
src/router.js              hash router (#/path), keeps invite tokens out of server logs
src/state.js               who is signed in, bartender/regular mode, pending invite
src/supabase.js            Supabase client
src/lib/                   DOM helpers, time/bar-day maths, image compression, toasts
src/views/                 one file per screen (bartender/, regular/)
src/styles/                theme tokens, base, components
supabase/migrations/       schema, privacy helpers, RLS, functions, storage
supabase/tests/            privacy + reactions/replies test suites (roll back; safe on the live project)
vercel.json                security headers (CSP etc.)
```

## Run locally

```bash
npm install
npm run dev        # http://localhost:5173
npm run build      # production build in dist/
```

`.env` holds the project URL and the **publishable** key. Both are meant to be public; the RLS policies are what protect the data.

## One-time setup you need to do

### 1. Turn on phone sign-in (Twilio)

1. Create a Twilio account. Buy a phone number, or better, create a **Messaging Service** (Twilio Console → Messaging → Services).
2. In Supabase: **Authentication → Sign In / Providers → Phone**. Enable it, choose **Twilio**, then paste your Account SID, Auth Token and Message Service SID.
3. Optional, for testing without spending SMS credit: in the same panel, add **Test phone numbers** with fixed codes (e.g. `+15555550100` → `123456`).
4. **Authentication → Rate Limits:** keep SMS limits modest (e.g. 30/hour). This protects your Twilio bill.

### 2. Deploy on Vercel

1. In Vercel: **Add New → Project** → import `the-theile/the-usual`.
2. Framework preset: **Vite** (build `npm run build`, output `dist`). No environment variables are needed because `.env` is committed.
3. Deploy. Every push to `master` redeploys.

The QR codes and invite links use the site's own address, so they work on whatever domain Vercel gives you.

### 3. Run the privacy tests on the live database (optional, recommended)

Paste `supabase/tests/privacy_test.sql` into the Supabase **SQL editor** and run it. It creates throwaway test users, checks 74 privacy rules and then **rolls everything back**. It should end without a `FAIL:` error.

Do the same with `supabase/tests/post_responses_test.sql` (54 checks for reactions and replies), `supabase/tests/post_visibility_test.sql` (26 checks for public vs. regulars-only posts) `supabase/tests/regular_profiles_test.sql` (62 checks for regular profiles, photos and bartender notes), `supabase/tests/delete_account_test.sql` (account deletion), `supabase/tests/pinned_post_test.sql` (pinned updates) and `supabase/tests/checkins_test.sql` (I'm coming tonight).

## Security notes

- RLS is on for every table. Clients can't write connections, blocks or invites directly. Those changes go through `SECURITY DEFINER` functions that enforce the rules.
- Visibility helpers live in a `private` schema that the API doesn't expose, so nobody can ask "am I blocked?".
- Invite codes: two words from a curated 499-word list plus a number from 10 to 99 (about 22 million combinations). Only one bar day's codes are live at a time. Code entry is rate-limited: 5 wrong tries per 10 minutes and 20 per day per account, and 50 per hour per IP address. A blocked person gets exactly the same "didn't work" answer as a typo.
- QR codes and links use 122-bit random tokens.
- A regular's photo, usual and birthday live in `regular_details`, not `profiles`, because `profiles` rows are also readable by a bartender's regulars.
- Photos are in private buckets, served by short-lived signed URLs under the same rules as the posts and profiles they belong to.

## Planned later (the schema is ready)

- **Direct messages:** `connections.messaging_enabled`. The bartender turns messaging on per regular.
- **Notification bell:** `connections.notify`, plus a `push_subscriptions` table.
- **Report button:** a new `reports` table.
- **Paid promotion:** a shared `venues` table and promoted posts.

New tables in `public` automatically get Supabase's default grants. Always add `revoke`/`grant` and RLS policies in the same migration, following the pattern in `20261031000003_rls.sql`.
