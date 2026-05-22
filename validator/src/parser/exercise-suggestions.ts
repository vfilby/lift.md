import dictionary from '../data/exercise-dictionary.json' with { type: 'json' };

interface ExerciseDefinition {
  canonical: string;
  aliases: string[];
  muscleGroups: string[];
  category: string;
}

const definitions = dictionary as ExerciseDefinition[];

const aliasToCanonical: Map<string, string> = (() => {
  const map = new Map<string, string>();
  for (const entry of definitions) {
    map.set(entry.canonical.toLowerCase(), entry.canonical);
    for (const alias of entry.aliases) {
      map.set(alias.toLowerCase(), entry.canonical);
    }
  }
  return map;
})();

const allKnownNames: string[] = (() => {
  const names = new Set<string>();
  for (const entry of definitions) {
    names.add(entry.canonical.toLowerCase());
    for (const alias of entry.aliases) names.add(alias.toLowerCase());
  }
  return [...names];
})();

export interface AliasResolution {
  canonical: string;
  matchedAlias: string;
  inputIsCanonical: boolean;
}

export interface FuzzySuggestion {
  suggestion: string;
  matched: string;
  distance: number;
}

export function resolveAlias(name: string): AliasResolution | null {
  const lower = name.trim().toLowerCase();
  const canonical = aliasToCanonical.get(lower);
  if (!canonical) return null;
  return {
    canonical,
    matchedAlias: lower,
    inputIsCanonical: lower === canonical.toLowerCase(),
  };
}

const MIN_FUZZY_LENGTH = 5;
const MAX_NORMALIZED_DISTANCE = 0.25;

export function fuzzyMatch(name: string): FuzzySuggestion | null {
  const lower = name.trim().toLowerCase();
  if (lower.length < MIN_FUZZY_LENGTH) return null;
  if (aliasToCanonical.has(lower)) return null;

  let best: FuzzySuggestion | null = null;
  for (const candidate of allKnownNames) {
    if (candidate.length < MIN_FUZZY_LENGTH) continue;
    const d = levenshtein(lower, candidate);
    const norm = d / Math.max(lower.length, candidate.length);
    if (norm > MAX_NORMALIZED_DISTANCE) continue;
    if (best === null || d < best.distance) {
      const canonical = aliasToCanonical.get(candidate);
      if (!canonical) continue;
      best = { suggestion: canonical, matched: candidate, distance: d };
    }
  }
  return best;
}

function levenshtein(a: string, b: string): number {
  if (a === b) return 0;
  if (a.length === 0) return b.length;
  if (b.length === 0) return a.length;
  const prev = new Array<number>(b.length + 1);
  const curr = new Array<number>(b.length + 1);
  for (let j = 0; j <= b.length; j++) prev[j] = j;
  for (let i = 1; i <= a.length; i++) {
    curr[0] = i;
    for (let j = 1; j <= b.length; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      curr[j] = Math.min(curr[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost);
    }
    for (let j = 0; j <= b.length; j++) prev[j] = curr[j];
  }
  return prev[b.length];
}
