// Homepage LMWF validator demo form.
//
// External module (not `is:inline`) so a strict `script-src 'self'` CSP set by
// the CloudFront ResponseHeadersPolicy accepts it without an inline hash.
(function () {
  const form = document.getElementById('validator-form');
  const textarea = document.getElementById('markdown');
  const button = document.getElementById('validate-btn');
  const statusEl = document.getElementById('validator-status');
  const resultEl = document.getElementById('validator-result');
  if (!form) return;
  const ENDPOINT = 'https://workoutformat.liftmark.app/validate';

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function renderIssueList(items) {
    if (!items || items.length === 0) return '';
    return (
      '<ul>' +
      items.map(function (it) { return '<li>' + escapeHtml(String(it)) + '</li>'; }).join('') +
      '</ul>'
    );
  }

  function renderSummary(summary) {
    if (!summary || typeof summary !== 'object') return '';
    const rows = [];
    if (summary.workoutName) rows.push(['Workout', summary.workoutName]);
    if (typeof summary.exerciseCount === 'number') rows.push(['Exercises', String(summary.exerciseCount)]);
    if (typeof summary.totalSetCount === 'number') rows.push(['Total sets', String(summary.totalSetCount)]);
    if (rows.length === 0) return '';
    return (
      '<dl>' +
      rows
        .map(function (r) {
          return '<dt>' + escapeHtml(r[0]) + '</dt><dd>' + escapeHtml(r[1]) + '</dd>';
        })
        .join('') +
      '</dl>'
    );
  }

  function render(data) {
    const hasErrors = Array.isArray(data.errors) && data.errors.length > 0;
    const hasWarnings = Array.isArray(data.warnings) && data.warnings.length > 0;
    const ok = data.success === true && !hasErrors;

    if (ok) {
      let html = '<div class="result ok">';
      html += '<h3>OK — valid LMWF</h3>';
      html += renderSummary(data.summary);
      if (hasWarnings) {
        html += '<p style="margin:0.75rem 0 0"><strong>Warnings</strong></p>';
        html += renderIssueList(data.warnings);
      }
      html += '</div>';
      resultEl.innerHTML = html;
      return;
    }

    let html = '<div class="result err">';
    html += '<h3>Errors</h3>';
    if (hasErrors) {
      html += renderIssueList(data.errors);
    } else {
      html += '<p style="margin:0">Validation failed.</p>';
    }
    if (hasWarnings) {
      html += '<p style="margin:0.75rem 0 0"><strong>Warnings</strong></p>';
      html += renderIssueList(data.warnings);
    }
    html += '</div>';
    resultEl.innerHTML = html;
  }

  form.addEventListener('submit', async function (e) {
    e.preventDefault();
    const markdown = textarea.value;
    button.disabled = true;
    statusEl.textContent = 'Validating...';
    resultEl.innerHTML = '';
    try {
      const res = await fetch(ENDPOINT, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ markdown: markdown }),
      });
      if (!res.ok) {
        statusEl.textContent = '';
        resultEl.innerHTML =
          '<div class="result err"><h3>Errors</h3><p style="margin:0">Validator returned HTTP ' +
          escapeHtml(String(res.status)) +
          '.</p></div>';
        return;
      }
      const data = await res.json();
      statusEl.textContent = '';
      render(data);
    } catch (err) {
      statusEl.textContent = '';
      resultEl.innerHTML =
        '<div class="result err"><h3>Errors</h3><p style="margin:0">Network error: ' +
        escapeHtml(err && err.message ? err.message : String(err)) +
        '</p></div>';
    } finally {
      button.disabled = false;
    }
  });
})();
