// Shared changelog generation for TestFlight "What to Test" notes.
//
// Builds notes deterministically from conventional-commit subjects — no LLM, no
// extra secret. `feat:` commits become a "New" list, `fix:` commits a "Fixed"
// list; trailing PR refs like "(#486)" are stripped for tester-facing prose.
//
// Two classes of commit are dropped as non-tester-facing: those whose scope is
// in EXCLUDE_SCOPES (default "ci"), and those whose subject matches
// EXCLUDE_PATTERN (default: test-infrastructure churn).
//
// Used by:
//   set-beta-notes.mjs      — upload-time notes for a single build (range: prev release..HEAD)
//   promote-preflight.mjs   — rollup notes at promotion (range: last Pre-flight..promoted build)
//
// Env (read once at import):
//   EXCLUDE_SCOPES    — optional; comma-separated scopes to drop (default "ci")
//   EXCLUDE_PATTERN   — optional; JS regex (case-insensitive) dropping matching subjects

import { execSync } from 'node:child_process';

export const CHAR_LIMIT = 4000; // App Store Connect whatsNew max length

// Subjects that are real commits but not tester-facing: test scaffolding,
// flaky-test stabilization, snapshot/UI/unit test repair, CI plumbing wording.
const DEFAULT_EXCLUDE_PATTERN =
  '\\b(ui|unit|snapshot)\\s+tests?\\b|\\bnightly\\b|\\bflaky\\b|waitfor\\w+|\\btest\\s+(suite|harness|plan)\\b';

const excludeScopes = new Set(
  (process.env.EXCLUDE_SCOPES ?? 'ci')
    .split(',')
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean),
);
const excludePattern = new RegExp(process.env.EXCLUDE_PATTERN || DEFAULT_EXCLUDE_PATTERN, 'i');

function capitalize(s) {
  // Leave camelCase / brand tokens like iCloud, iPad, iOS untouched.
  if (/^[a-z][A-Z]/.test(s)) return s;
  return s.charAt(0).toUpperCase() + s.slice(1);
}

// Resolve a marketing version to an existing tag ref. The pipeline tags new
// releases deploy/<version>; the pre-existing scheme used alpha-v<version>. Try
// both. Returns the ref string, or null if neither tag exists.
export function resolveVersionRef(version) {
  if (!version) return null;
  for (const ref of [`deploy/${version}`, `alpha-v${version}`]) {
    try {
      execSync(`git rev-parse --verify --quiet "${ref}^{commit}"`, { stdio: 'pipe' });
      return ref;
    } catch {
      // try next candidate
    }
  }
  return null;
}

// Generate "What to Test" notes from feat/fix commits in (lowerRef, upperRef].
// lowerRef null → from the start of history. Returns the notes string, or null
// when the range contains no tester-facing feat/fix commits.
export function generateNotes(lowerRef, upperRef = 'HEAD') {
  const range = lowerRef ? `${lowerRef}..${upperRef}` : upperRef;
  const raw = execSync(`git log --no-merges --format=%s ${range}`, { encoding: 'utf8' });
  const subjects = raw.split('\n').map((s) => s.trim()).filter(Boolean);

  const features = [];
  const fixes = [];
  for (const s of subjects) {
    const m = s.match(/^(feat|fix)(?:\(([^)]*)\))?!?:\s*(.+)$/i);
    if (!m) continue;
    const type = m[1].toLowerCase();
    const scope = (m[2] || '').toLowerCase();
    // Strip trailing PR refs like " (#486)" or " (#486) (#500)".
    const text = m[3].replace(/\s*\(#\d+\)/g, '').trim();
    if (!text) continue;
    // Drop non-tester-facing noise: excluded scopes (e.g. ci) and test churn.
    if (excludeScopes.has(scope)) continue;
    if (excludePattern.test(text)) continue;
    (type === 'feat' ? features : fixes).push(capitalize(text));
  }

  if (features.length === 0 && fixes.length === 0) return null;

  const lines = [];
  if (features.length) {
    lines.push('New:');
    for (const f of features) lines.push(`• ${f}`);
  }
  if (fixes.length) {
    if (lines.length) lines.push('');
    lines.push('Fixed:');
    for (const f of fixes) lines.push(`• ${f}`);
  }
  let notes = lines.join('\n');
  if (notes.length > CHAR_LIMIT) notes = `${notes.slice(0, CHAR_LIMIT - 1)}…`;
  return notes;
}
