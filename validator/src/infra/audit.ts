/**
 * Single-line JSON audit logging.
 *
 * Every refresh-token / session state change emits one of these so we
 * can grep CloudWatch for forensic timelines after suspected token
 * theft. Stdout only — CloudWatch Logs is the storage layer.
 *
 * `level` defaults to 'info' (state change), warn for security-sensitive
 * events like reuse detection.
 */

export type AuditLevel = 'info' | 'warn';

export interface AuditEntry {
  event: string;
  user_id?: string;
  identity_id?: string;
  /** sha256 hex — never log the plaintext. */
  token_hash?: string;
  family_root_hash?: string;
  /** Free-form per-event payload. Avoid PII; never include the plaintext. */
  [key: string]: unknown;
}

export function audit(entry: AuditEntry, level: AuditLevel = 'info'): void {
  const line = {
    level,
    ts: new Date().toISOString(),
    ...entry,
  };
  if (level === 'warn') {
    console.warn(JSON.stringify(line));
  } else {
    console.log(JSON.stringify(line));
  }
}
