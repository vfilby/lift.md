// Apply the stored color-scheme as early as possible to minimize FOUC.
//
// This lives in an external module (imported, not `is:inline`) so a strict
// `script-src 'self'` CSP — set by the CloudFront ResponseHeadersPolicy —
// accepts it without an inline hash. Astro emits it as a deferred module
// script in <head>, so it runs before DOMContentLoaded.
(function () {
  try {
    var stored = localStorage.getItem('color-scheme');
    if (stored === 'light' || stored === 'dark') {
      document.documentElement.setAttribute('data-color-scheme', stored);
      document.documentElement.style.colorScheme = stored;
    }
  } catch (_) { /* storage unavailable */ }
})();
