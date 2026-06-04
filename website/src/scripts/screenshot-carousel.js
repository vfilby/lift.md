// Inline screenshot carousel for the home page.
//
// External module (not `is:inline`) so a strict `script-src 'self'` CSP set by
// the CloudFront ResponseHeadersPolicy accepts it without an inline hash.
//
// Keeps three screenshots visible (one on mobile) and slides the track one shot
// at a time via the side arrows. The number visible is read from the
// `--shots-per-view` CSS variable so the responsive breakpoint stays in CSS.
(function () {
  function init() {
    var root = document.querySelector('.shots');
    if (!root) return;
    var track = root.querySelector('.shots-track');
    var shots = track ? Array.prototype.slice.call(track.querySelectorAll('.shot')) : [];
    var prev = root.querySelector('.shots-prev');
    var next = root.querySelector('.shots-next');
    if (!track || !shots.length || !prev || !next) return;

    var index = 0;

    function perView() {
      var v = parseInt(getComputedStyle(root).getPropertyValue('--shots-per-view'), 10);
      return v > 0 ? v : 1;
    }

    function step() {
      var w = shots[0].getBoundingClientRect().width;
      var gap = parseFloat(getComputedStyle(track).gap) || 0;
      return w + gap;
    }

    function maxIndex() {
      return Math.max(0, shots.length - perView());
    }

    function render() {
      var max = maxIndex();
      if (index > max) index = max;
      if (index < 0) index = 0;
      track.style.transform = 'translateX(' + (-index * step()) + 'px)';
      prev.disabled = index <= 0;
      next.disabled = index >= max;
      // If everything fits, there's nothing to page through.
      var noPaging = max === 0;
      prev.hidden = noPaging;
      next.hidden = noPaging;
    }

    prev.addEventListener('click', function () { index -= 1; render(); });
    next.addEventListener('click', function () { index += 1; render(); });

    var raf = null;
    window.addEventListener('resize', function () {
      if (raf) cancelAnimationFrame(raf);
      raf = requestAnimationFrame(render);
    });

    // Recompute once images have loaded (their height can shift item width via
    // the aspect ratio before the intrinsic size is known).
    window.addEventListener('load', render);
    render();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
