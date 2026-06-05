import type { APIRoute } from 'astro';

// Downloadable bundle of the `generate-workout` Agent Skill, for tools that
// install skills by uploading a .zip (claude.ai, Cowork). Built at request
// time from the SAME single source of truth as /install.sh and /skill/* —
// tools/claude-skill/generate-workout/ — so the download can never drift.
//
// claude.ai's uploader wants the skill folder as the archive root, so the
// entries are `generate-workout/SKILL.md` and `generate-workout/validate.sh`.
//
// Zip is assembled by hand (stored / no compression) to avoid pulling in a
// zip dependency — the site keeps its dependency list to astro + marked.
import skillSource from '../../../tools/claude-skill/generate-workout/SKILL.md?raw';
import validateSource from '../../../tools/claude-skill/generate-workout/validate.sh?raw';

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(buf: Buffer): number {
  let crc = 0xffffffff;
  for (let i = 0; i < buf.length; i++) crc = CRC_TABLE[(crc ^ buf[i]) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

interface Entry {
  name: string;
  data: Buffer;
  /** Unix mode, e.g. 0o100644 (file) or 0o100755 (executable). */
  mode: number;
}

function buildZip(entries: Entry[]): Buffer {
  // Fixed DOS timestamp (2026-01-01 00:00) keeps the static build reproducible.
  const DOS_TIME = 0;
  const DOS_DATE = ((2026 - 1980) << 9) | (1 << 5) | 1;
  const locals: Buffer[] = [];
  const centrals: Buffer[] = [];
  let offset = 0;

  for (const e of entries) {
    const name = Buffer.from(e.name, 'utf8');
    const crc = crc32(e.data);
    const size = e.data.length;

    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0); // local file header signature
    local.writeUInt16LE(20, 4); // version needed
    local.writeUInt16LE(0, 6); // flags
    local.writeUInt16LE(0, 8); // method: stored
    local.writeUInt16LE(DOS_TIME, 10);
    local.writeUInt16LE(DOS_DATE, 12);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(size, 18); // compressed size
    local.writeUInt32LE(size, 22); // uncompressed size
    local.writeUInt16LE(name.length, 26);
    local.writeUInt16LE(0, 28); // extra length
    locals.push(local, name, e.data);

    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0); // central dir signature
    central.writeUInt16LE((3 << 8) | 20, 4); // version made by: unix
    central.writeUInt16LE(20, 6); // version needed
    central.writeUInt16LE(0, 8); // flags
    central.writeUInt16LE(0, 10); // method: stored
    central.writeUInt16LE(DOS_TIME, 12);
    central.writeUInt16LE(DOS_DATE, 14);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(size, 20);
    central.writeUInt32LE(size, 24);
    central.writeUInt16LE(name.length, 28);
    central.writeUInt16LE(0, 30); // extra
    central.writeUInt16LE(0, 32); // comment
    central.writeUInt16LE(0, 34); // disk number
    central.writeUInt16LE(0, 36); // internal attrs
    central.writeUInt32LE(((e.mode & 0xffff) << 16) >>> 0, 38); // external attrs: unix mode
    central.writeUInt32LE(offset, 42); // local header offset
    centrals.push(central, name);

    offset += local.length + name.length + e.data.length;
  }

  const centralStart = offset;
  const centralSize = centrals.reduce((sum, b) => sum + b.length, 0);

  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0); // end of central dir signature
  end.writeUInt16LE(0, 4); // disk number
  end.writeUInt16LE(0, 6); // central dir start disk
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(centralSize, 12);
  end.writeUInt32LE(centralStart, 16);
  end.writeUInt16LE(0, 20); // comment length

  return Buffer.concat([...locals, ...centrals, end]);
}

export const GET: APIRoute = () => {
  const zip = buildZip([
    {
      name: 'generate-workout/SKILL.md',
      data: Buffer.from(skillSource, 'utf8'),
      mode: 0o100644,
    },
    {
      name: 'generate-workout/validate.sh',
      data: Buffer.from(validateSource, 'utf8'),
      mode: 0o100755,
    },
  ]);

  return new Response(zip, {
    status: 200,
    headers: {
      'Content-Type': 'application/zip',
      'Content-Disposition': 'attachment; filename="generate-workout.zip"',
      'Cache-Control': 'public, max-age=300',
    },
  });
};
