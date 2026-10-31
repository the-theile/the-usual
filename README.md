# The Usual

Bartenders tell their regulars where they're working, without sharing a phone number or social media.

A mobile-first web app built with plain JavaScript and Vite, with Supabase for sign-in, the database and photos. There is no UI framework.

## What's in Version 1

- Sign-in with a phone number and a one-time SMS code. Phone numbers are never shown to anyone.
- **Bartenders:** photo, name, bio, the bars they work at.
- **Invite a regular:** a QR code, today's spoken code (e.g. `TIKI-MOON-42`, changes at 5am local time) and a copy-able link that lasts 7 days. All three connect the regular instantly.
- **Posts:** text with an optional photo. Photos are resized and re-encoded in the browser, which also removes GPS/EXIF data.
- **Schedule:** one-off shifts, weekly shifts, and changing or cancelling a single night.
- **Schedule privacy:** "Only my regulars" or "Anyone with my link" (signed-in users only).
- **Regular home:** who's working tonight, then recent posts.
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
supabase/tests/            privacy test suite (rolls back; safe on the live project)
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

## Security notes

- RLS is on for every table. Clients can't write connections, blocks or invites directly. Those changes go through `SECURITY DEFINER` functions that enforce the rules.
- Visibility helpers live in a `private` schema that the API doesn't expose, so nobody can ask "am I blocked?".
- Invite codes: two words from a curated 499-word list plus a number from 10 to 99 (about 22 million combinations). Only one bar day's codes are live at a time. Code entry is rate-limited: 5 wrong tries per 10 minutes and 20 per day per account, and 50 per hour per IP address. A blocked person gets exactly the same "didn't work" answer as a typo.
- QR codes and links use 122-bit random tokens.
- Photos are in private buckets, served by short-lived signed URLs under the same rules as the posts and profiles they belong to.

## Planned later (the schema is ready)

- **Direct messages:** `connections.messaging_enabled`. The bartender turns messaging on per regular.
- **Notification bell:** `connections.notify`, plus a `push_subscriptions` table.
- **Report button:** a new `reports` table.
- **Paid promotion:** a shared `venues` table and promoted posts.

New tables in `public` automatically get Supabase's default grants. Always add `revoke`/`grant` and RLS policies in the same migration, following the pattern in `20261031000003_rls.sql`.
