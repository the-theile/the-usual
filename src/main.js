import './styles/theme.css';
import './styles/base.css';
import './styles/components.css';

import { supabase } from './supabase.js';
import { me, loadMe, getMode } from './state.js';
import { route, match, parseHash, navigate } from './router.js';
import { h, screen } from './lib/dom.js';

import { welcomeView } from './views/welcome.js';
import { signinView } from './views/signin.js';
import { onboardingView, becomeBartenderView } from './views/onboarding.js';
import { joinView } from './views/join.js';
import { bartenderHomeView } from './views/bartender/home.js';
import { postView } from './views/bartender/post.js';
import { inviteView } from './views/bartender/invite.js';
import { scheduleView, weeklyFormView, onceFormView, nightFormView } from './views/bartender/schedule.js';
import { profileView } from './views/bartender/profile.js';
import { regularsView } from './views/bartender/regulars.js';
import { regularHomeView } from './views/regular/home.js';
import { enterCodeView } from './views/regular/enter-code.js';
import { bartenderPageView } from './views/regular/bartender.js';

// ===== Routes =====
const B = { bartender: true };
route('/', async (ctx) => (me.bartender && getMode() !== 'regular' ? bartenderHomeView(ctx) : regularHomeView(ctx)));
route('/welcome', welcomeView, { public: true });
route('/signin', signinView, { public: true });
route('/join', joinView, { public: true });
route('/onboarding', onboardingView, { noProfile: true });
route('/become-bartender', becomeBartenderView);
route('/code', enterCodeView);
route('/b/:pid', bartenderPageView);
route('/post', postView, B);
route('/invite', inviteView, B);
route('/schedule', scheduleView, B);
route('/schedule/weekly/new', weeklyFormView, B);
route('/schedule/weekly/:id', weeklyFormView, B);
route('/schedule/once/new', onceFormView, B);
route('/schedule/once/:id', onceFormView, B);
route('/schedule/night/:patternId/:date', nightFormView, B);
route('/profile', profileView, B);
route('/regulars', regularsView, B);

// ===== Rendering =====
const app = document.getElementById('app');
let renderSeq = 0;

async function render() {
  const seq = ++renderSeq;
  const { path, query } = parseHash();
  const r = match(path) || match('/');
  const signedIn = !!me.session;

  if (!r.opts.public && !signedIn) return navigate('/welcome', { replace: true });
  if (signedIn && !me.profile && !r.opts.public && !r.opts.noProfile) return navigate('/onboarding', { replace: true });
  if (signedIn && me.profile && (path === '/welcome' || path === '/signin' || path === '/onboarding')) {
    return navigate('/', { replace: true });
  }
  if (r.opts.bartender && !me.bartender) return navigate('/', { replace: true });

  let node;
  try {
    node = await r.view({ params: r.params, query, path });
  } catch (err) {
    console.error(err);
    node = screen(
      h('h1', {}, 'Sorry, something went wrong'),
      h('p', {}, 'Please check your internet connection and try again.'),
      h('button', { type: 'button', class: 'btn btn-primary', onClick: () => location.reload() }, 'Try again'),
      h('a', { class: 'btn btn-ghost', href: '#/' }, 'Go to my home screen'),
    );
  }
  if (seq !== renderSeq || !node) return; // a newer navigation won
  app.replaceChildren(node);
  window.scrollTo(0, 0);
  const auto = app.querySelector('[data-autofocus]');
  (auto || app).focus({ preventScroll: true });
}

window.addEventListener('hashchange', render);

supabase.auth.onAuthStateChange((event, session) => {
  // Don't await Supabase calls inside this callback (supabase-js deadlock); defer.
  setTimeout(async () => {
    if (event === 'SIGNED_OUT') {
      me.session = null; me.profile = null; me.bartender = null;
      navigate('/welcome', { replace: true });
    } else if (event === 'TOKEN_REFRESHED' || event === 'USER_UPDATED') {
      me.session = session;
    }
  }, 0);
});

loadMe().then(render, (err) => { console.error(err); render(); });
