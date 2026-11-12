# The Usual iOS app (Capacitor)

The iOS app is a Capacitor shell that loads the live site (`https://gettheusual.bar`,
see `capacitor.config.json`). Web deploys update the app without an App Store release;
only native changes (plugins, permissions, icons) need a new build. Set up the same way
as RaveFAM's, with the fixes its App Review taught us already in place.

- `native/www/` — offline fallback page bundled into the app (shown when the site can't load).
- `ios/` — Xcode project (Swift Package Manager, no CocoaPods). Bundle ID `bar.gettheusual.app`,
  Team ID `49RV4NFK6S` (same Apple team as RaveFAM).
- `public/.well-known/apple-app-site-association` — Universal Links: invite links and QR codes
  (`/#/join…`), bartender pages (`/#/b/…`, `/tender/…`).
- `src/lib/native.js` — on the web side: detects the app (`html.is-native-app`), opens Universal
  Links, and hides the "Add to Home Screen" tips. `public/native-legal.js` gives Terms/Privacy a
  "‹ Back to The Usual" link inside the app.

After changing `capacitor.config.json` or adding a plugin: `npm run ios:sync`.

## Already handled (lessons from RaveFAM)
- One window on launch: `Info.plist` names no `Main` scene/main storyboard (Capacitor's template
  still does). RaveFAM's iPad "taps do nothing" rejection (2.1(a)) came from the second window.
- `UIRequiredDeviceCapabilities` is `arm64` (template says `armv7`).
- `ITSAppUsesNonExemptEncryption` is false, so no export-compliance question on every build.
- Privacy manifest (`ios/App/App/PrivacyInfo.xcprivacy`) lists what the app collects. App Store
  Connect's App Privacy answers must match it.
- Camera usage string: the photo picker offers "Take Photo", which crashes without one.
- Edge swipe-back only on pages outside the app (Terms, Privacy).

## First build: one-time setup
1. **App Store Connect → Apps → +  New App**: platform iOS, name "The Usual", bundle ID
   `bar.gettheusual.app` (register it under Certificates, IDs & Profiles → Identifiers first if
   it isn't offered; tick **Associated Domains**), SKU e.g. `theusual-ios`.
2. **GitHub → the-usual → Settings → Secrets and variables → Actions**: add
   `APP_STORE_CONNECT_API_KEY` with the full text of the same `AuthKey_GK73389T2F.p8` RaveFAM
   uses (the key belongs to the team, not the app).
3. Merge to `master` so Vercel serves `/.well-known/apple-app-site-association`, then check
   `https://gettheusual.bar/.well-known/apple-app-site-association` returns the JSON.
4. Run **Actions → iOS TestFlight → Run workflow** on `master`.

## Builds
Run **Actions -> iOS TestFlight -> Run workflow** on `master`. The App Store version is
`package.json`'s `version`; the build number is the workflow run number.

## Releases
Web changes reach the app on deploy; only native changes (Swift, `capacitor.config.json`,
plugins, entitlements, Info.plist, icons) need an App Store submission. Batch them like RaveFAM:
merge native changes as they're ready, test on TestFlight, and submit when the list below has
something worth shipping. Crashes or a broken core flow (sign-in) ship right away.

### Next iOS release
Each native PR adds a line here; **After release** holds web changes that wait on it.

- First release: the Capacitor shell, Universal Links, offline page, privacy manifest.

**After release**

### Released
_Nothing yet._
