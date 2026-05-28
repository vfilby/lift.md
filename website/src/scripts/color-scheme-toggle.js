// Color-scheme toggle button (auto → light → dark cycle).
//
// External module (not `is:inline`) so a strict `script-src 'self'` CSP set by
// the CloudFront ResponseHeadersPolicy accepts it without an inline hash.
(function () {
  var icons = {
    light: ['☼', 'Light mode (click for dark)'],
    dark:  ['☾', 'Dark mode (click for auto)'],
    auto:  ['◑', 'Auto / system (click for light)'],
  };
  var cycle = ['auto', 'light', 'dark'];

  function applyScheme(scheme) {
    var root = document.documentElement;
    var btn = document.getElementById('color-toggle');
    if (scheme === 'light' || scheme === 'dark') {
      root.setAttribute('data-color-scheme', scheme);
      root.style.colorScheme = scheme;
    } else {
      root.removeAttribute('data-color-scheme');
      root.style.colorScheme = 'light dark';
    }
    if (btn) {
      var entry = icons[scheme] || icons.auto;
      btn.textContent = entry[0];
      btn.title = entry[1];
      btn.setAttribute('aria-label', entry[1]);
    }
  }

  function currentScheme() {
    try {
      var v = localStorage.getItem('color-scheme');
      if (v === 'light' || v === 'dark') return v;
    } catch (_) {}
    return 'auto';
  }

  function init() {
    var scheme = currentScheme();
    applyScheme(scheme);
    var btn = document.getElementById('color-toggle');
    if (!btn || btn.dataset.bound === '1') return;
    btn.dataset.bound = '1';
    btn.addEventListener('click', function () {
      var next = cycle[(cycle.indexOf(currentScheme()) + 1) % cycle.length];
      try {
        if (next === 'auto') localStorage.removeItem('color-scheme');
        else localStorage.setItem('color-scheme', next);
      } catch (_) {}
      applyScheme(next);
    });
  }

  // The toggle button lives in markup that is already parsed by the time this
  // deferred module runs, but guard with DOMContentLoaded in case Astro hoists
  // the script ahead of the body in some output mode.
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
