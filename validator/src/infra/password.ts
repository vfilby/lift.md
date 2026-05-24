/**
 * Password hashing helpers.
 *
 * argon2id via @node-rs/argon2 (Rust core, pre-built native binaries for
 * darwin-arm64 and linux-arm64 — both the dev box and the Lambda runtime).
 * Defaults are OWASP-recommended for interactive logins: 64 MiB memory,
 * 2 iterations, 1 thread (single-core Lambda).
 *
 * Two functions only: hash a plaintext, verify a plaintext against a hash.
 * The encoded hash carries its own parameters, so verification doesn't
 * need to know what was used at hash time.
 */
import { hash, verify, Algorithm } from '@node-rs/argon2';

const HASH_OPTS = {
  algorithm: Algorithm.Argon2id,
  memoryCost: 65536,
  timeCost: 2,
  parallelism: 1,
} as const;

export async function hashPassword(plain: string): Promise<string> {
  return hash(plain, HASH_OPTS);
}

export async function verifyPassword(
  plain: string,
  hashed: string,
): Promise<boolean> {
  try {
    return await verify(hashed, plain);
  } catch {
    // Malformed hash, wrong algorithm, etc. — treat as a mismatch so we
    // don't leak detail via 500s on a login route.
    return false;
  }
}
