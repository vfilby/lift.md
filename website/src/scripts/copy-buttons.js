// Wire up any `[data-copy]` button to copy its attribute value to the
// clipboard and flash "Copied". Used by the hero's skill-install one-liner.
//
// External module (not `is:inline`) so a strict `script-src 'self'` CSP set by
// the CloudFront ResponseHeadersPolicy accepts it without an inline hash.
(function () {
  var buttons = document.querySelectorAll('[data-copy]');
  if (!buttons.length) return;

  function flash(btn) {
    var original = btn.textContent;
    btn.textContent = 'Copied';
    btn.classList.add('copied');
    setTimeout(function () {
      btn.textContent = original;
      btn.classList.remove('copied');
    }, 1600);
  }

  function legacyCopy(text, btn) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    try {
      document.execCommand('copy');
      flash(btn);
    } catch (_) {
      /* nothing we can do */
    }
    document.body.removeChild(ta);
  }

  buttons.forEach(function (btn) {
    btn.addEventListener('click', function () {
      var text = btn.getAttribute('data-copy') || '';
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(
          function () {
            flash(btn);
          },
          function () {
            legacyCopy(text, btn);
          },
        );
      } else {
        legacyCopy(text, btn);
      }
    });
  });
})();
