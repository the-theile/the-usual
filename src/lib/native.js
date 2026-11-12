// The iOS app (Capacitor shell, see native/README.md) loads this same site in a
// webview and injects window.Capacitor. Everything here no-ops in a browser.

export function isNativeApp() {
  return !!window.Capacitor?.isNativePlatform?.();
}

// Universal Links (gettheusual.bar/#/join?t=…, /tender/<handle>) open the app;
// the App plugin hands us the URL. Same site only.
function openAppUrl(url) {
  try {
    const target = new URL(url);
    if (target.host !== location.host || target.href === location.href) return;
    location.href = target.href; // a hash-only change just re-routes
  } catch (e) {
    console.error('native app: bad app URL', url, e);
  }
}

/** Call once at startup. */
export function initNative() {
  if (!isNativeApp()) return;
  document.documentElement.classList.add('is-native-app');
  const App = window.Capacitor.Plugins?.App;
  if (!App) return;
  App.addListener('appUrlOpen', (e) => openAppUrl(e.url));
  // A link that cold-launched the app. Remember it so a reload doesn't replay it.
  App.getLaunchUrl().then((launch) => {
    if (!launch?.url) return;
    try {
      if (sessionStorage.getItem('usual.launchUrl') === launch.url) return;
      sessionStorage.setItem('usual.launchUrl', launch.url);
    } catch { /* storage blocked */ }
    openAppUrl(launch.url);
  }).catch((e) => console.error('native app: getLaunchUrl failed', e));
}
