// Home page: morph the big hero logo into the small nav icon as the page
// scrolls. Scroll progress (0 → 1 over the first MORPH_DISTANCE px) drives:
//   - the hero logo: shrinks + lifts + fades out
//   - the nav icon tile: fades in
// so the two cross over and read as one logo docking into the nav bar.
//
// External module (not `is:inline`) so a strict `script-src 'self'` CSP set by
// the CloudFront ResponseHeadersPolicy accepts it without an inline hash.
(function () {
  if (!document.body.hasAttribute('data-home')) return;
  // Drive the wrapper, not the <img>s: it holds both the ink + white lockup
  // variants (only the theme-appropriate one is shown), so transforming the
  // wrapper morphs whichever variant is visible.
  var heroLogo = document.querySelector('.hero-logo-wrap');
  if (!heroLogo) return;
  var navIcon = document.querySelector('.brand-icon');

  var MORPH_DISTANCE = 220; // px of scroll over which the morph completes
  var ticking = false;

  function clamp01(n) {
    return n < 0 ? 0 : n > 1 ? 1 : n;
  }

  function apply() {
    ticking = false;
    var p = clamp01(window.scrollY / MORPH_DISTANCE);
    // Hero shrinks toward the nav, lifts slightly, and fades out.
    heroLogo.style.opacity = String(1 - p);
    heroLogo.style.transform =
      'translateY(' + -p * 36 + 'px) scale(' + (1 - 0.62 * p) + ')';
    // Once mostly gone, drop it out of the hit-test so it can't block clicks.
    heroLogo.style.pointerEvents = p > 0.5 ? 'none' : '';
    // Nav icon fades in as the hero fades out.
    if (navIcon) navIcon.style.opacity = String(p);
  }

  function onScroll() {
    if (!ticking) {
      ticking = true;
      window.requestAnimationFrame(apply);
    }
  }

  apply();
  window.addEventListener('scroll', onScroll, { passive: true });
  window.addEventListener('resize', onScroll, { passive: true });
})();
