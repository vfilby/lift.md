// Screenshot lightbox + carousel for the home page.
//
// External module (not `is:inline`) so a strict `script-src 'self'` CSP set by
// the CloudFront ResponseHeadersPolicy accepts it without an inline hash.
//
// Reads the three `.shots .shot` figures, and on click opens a modal overlay
// showing an enlarged copy. The lightbox `<img>`s carry the same
// `shot-light`/`shot-dark` classes as the thumbnails, so the existing CSS
// theme-swap rules pick the right variant — including live theme toggles.
(function () {
  function init() {
    var section = document.querySelector('.shots');
    var lb = document.getElementById('lightbox');
    if (!section || !lb) return;

    var shots = Array.prototype.slice.call(section.querySelectorAll('.shot'));
    if (!shots.length) return;

    // Build the slide list from each shot's full-size sources (data-full-*),
    // not the small carousel thumbnails. Alt text comes from the thumbnail img.
    var slides = shots.map(function (shot) {
      var light = shot.querySelector('.shot-light');
      return {
        light: shot.getAttribute('data-full-light') || (light ? light.getAttribute('src') : ''),
        dark: shot.getAttribute('data-full-dark') || '',
        alt: (light && light.getAttribute('alt')) || '',
      };
    });

    var imgLight = lb.querySelector('.lightbox-img.shot-light');
    var imgDark = lb.querySelector('.lightbox-img.shot-dark');
    var counter = lb.querySelector('.lightbox-counter');
    var btnPrev = lb.querySelector('.lightbox-prev');
    var btnNext = lb.querySelector('.lightbox-next');
    var btnClose = lb.querySelector('.lightbox-close');

    var current = 0;
    var lastFocus = null;

    function render() {
      var s = slides[current];
      imgLight.setAttribute('src', s.light);
      imgDark.setAttribute('src', s.dark);
      imgLight.setAttribute('alt', s.alt);
      imgDark.setAttribute('alt', s.alt);
      if (counter) counter.textContent = (current + 1) + ' / ' + slides.length;
    }

    function step(delta) {
      current = (current + delta + slides.length) % slides.length;
      render();
    }

    function open(index) {
      current = index;
      render();
      lastFocus = document.activeElement;
      lb.hidden = false;
      // Lock background scroll while the modal is up.
      document.documentElement.style.overflow = 'hidden';
      btnClose.focus();
    }

    function close() {
      lb.hidden = true;
      document.documentElement.style.overflow = '';
      if (lastFocus && typeof lastFocus.focus === 'function') lastFocus.focus();
    }

    // Each thumbnail opens the lightbox at its index.
    shots.forEach(function (shot, i) {
      shot.addEventListener('click', function () { open(i); });
    });

    btnPrev.addEventListener('click', function () { step(-1); });
    btnNext.addEventListener('click', function () { step(1); });
    btnClose.addEventListener('click', close);

    // Click on the dimmed backdrop (but not the image or controls) closes.
    lb.addEventListener('click', function (e) {
      if (e.target === lb || e.target.classList.contains('lightbox-stage')) close();
    });

    document.addEventListener('keydown', function (e) {
      if (lb.hidden) return;
      if (e.key === 'Escape') close();
      else if (e.key === 'ArrowLeft') step(-1);
      else if (e.key === 'ArrowRight') step(1);
    });

    // Touch swipe (horizontal) to step between slides.
    var touchX = null;
    lb.addEventListener('touchstart', function (e) {
      touchX = e.changedTouches[0].clientX;
    }, { passive: true });
    lb.addEventListener('touchend', function (e) {
      if (touchX === null) return;
      var dx = e.changedTouches[0].clientX - touchX;
      if (Math.abs(dx) > 40) step(dx < 0 ? 1 : -1);
      touchX = null;
    }, { passive: true });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
