// Toggle a `nav-scrolled` class on <html> once the page is scrolled past a
// small threshold. The sticky site header uses it to collapse from the full
// lift.md lockup to just the icon tile.
//
// External module (not `is:inline`) so a strict `script-src 'self'` CSP set by
// the CloudFront ResponseHeadersPolicy accepts it without an inline hash.
(function () {
  var root = document.documentElement;
  var THRESHOLD = 24;
  var ticking = false;

  function apply() {
    ticking = false;
    if (window.scrollY > THRESHOLD) root.classList.add('nav-scrolled');
    else root.classList.remove('nav-scrolled');
  }

  function onScroll() {
    if (!ticking) {
      ticking = true;
      window.requestAnimationFrame(apply);
    }
  }

  apply();
  window.addEventListener('scroll', onScroll, { passive: true });
})();
