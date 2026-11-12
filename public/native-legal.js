// Terms / Privacy inside the iOS app: there's no browser back button, and these
// pages usually open from sign-in. Turn the logo link into "‹ Back", which
// returns to where the person was (falling back to the app's home screen).
(function () {
  if (!(window.Capacitor && window.Capacitor.isNativePlatform && window.Capacitor.isNativePlatform())) return;
  var top = document.querySelector('a.top');
  if (!top) return;
  var label = top.querySelector('span');
  if (label) label.textContent = '‹ Back to The Usual';
  top.addEventListener('click', function (e) {
    if (history.length > 1) { e.preventDefault(); history.back(); }
  });
})();
