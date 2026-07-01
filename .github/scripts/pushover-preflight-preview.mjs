// Sends a Pushover notification previewing the next Beta → Pre-flight promotion.
//
// Reads the JSON written by promote-preflight.mjs (via SUMMARY_FILE) and posts a
// concise message: which build is likely to promote, the rolled-up "What to Test"
// changes, and any build whose only blocker is soak that will clear it before the
// real promotion (LEAD_HOURS later). Best-effort — a Pushover failure exits non-zero
// so the workflow surfaces it, but nothing here touches the promotion itself.
//
// Env:
//   SUMMARY_FILE   — path to the evaluation JSON (required)
//   PUSHOVER_TOKEN — Pushover application/API token (required)
//   PUSHOVER_USER  — Pushover user/group key (required)
//   LEAD_HOURS     — hours between this preview and the actual promote (default 9)
//   PROMOTE_WHEN   — human label for the promote time (default 'Tue 12:00 UTC')

import { readFileSync } from 'node:fs';

const MESSAGE_LIMIT = 1024; // Pushover message hard cap

function required(name) {
  const v = process.env[name];
  if (!v) throw new Error(`Missing required env: ${name}`);
  return v;
}

function clamp(s) {
  return s.length > MESSAGE_LIMIT ? `${s.slice(0, MESSAGE_LIMIT - 1)}…` : s;
}

function buildMessage(summary, leadHours, promoteWhen) {
  const lines = [];
  const target = summary.targetGroup || 'Pre-flight';
  const current = summary.currentTargetBuild ? ` (current ${target}: ${summary.currentTargetBuild})` : '';

  if (summary.eligible) {
    lines.push(`<b>Build ${summary.build} (v${summary.version})</b> likely promotes to ${target} ${promoteWhen}${current}.`);
    lines.push('');
    if (summary.notes) {
      lines.push('<b>What to Test</b>');
      lines.push(summary.notes);
    } else {
      lines.push('No rolled-up "What to Test"; build keeps its upload-time notes.');
    }
  } else {
    lines.push(`<b>No build currently eligible</b> for ${target}${current}. Nothing would promote ${promoteWhen}.`);
  }

  // Heads-up: builds blocked ONLY by soak that will pass the soak gate by promote
  // time. Their reason reads "soak X.Xh < Yh"; project age forward by leadHours.
  const soak = Number(summary.soakHours) || 0;
  const nearMiss = (summary.evaluation || [])
    .filter((e) => !e.eligible
      && e.reasons.length === 1
      && /^soak /.test(e.reasons[0])
      && e.ageHours + leadHours >= soak)
    .map((e) => `• build ${e.build} (v${e.version}): ${e.ageHours.toFixed(1)}h now → ~${(e.ageHours + leadHours).toFixed(1)}h at promote (soak ${soak}h)`);

  if (nearMiss.length) {
    lines.push('');
    lines.push('<b>May also qualify by promote time</b> (soak clears):');
    lines.push(...nearMiss);
  }

  return clamp(lines.join('\n'));
}

async function main() {
  const summary = JSON.parse(readFileSync(required('SUMMARY_FILE'), 'utf8'));
  const token = required('PUSHOVER_TOKEN');
  const user = required('PUSHOVER_USER');
  const leadHours = Number(process.env.LEAD_HOURS || '9');
  const promoteWhen = process.env.PROMOTE_WHEN || 'Tue 12:00 UTC';

  const title = summary.eligible
    ? `Pre-flight preview: build ${summary.build} → promote ${promoteWhen}`
    : `Pre-flight preview: none eligible for ${promoteWhen}`;

  const params = new URLSearchParams({
    token,
    user,
    title,
    message: buildMessage(summary, leadHours, promoteWhen),
    html: '1',
  });

  const res = await fetch('https://api.pushover.net/1/messages.json', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: params,
  });
  const body = await res.text();
  if (!res.ok) throw new Error(`Pushover → ${res.status}: ${body}`);
  console.log(`Pushover notification sent: ${title}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
