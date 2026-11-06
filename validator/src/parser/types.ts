// MARK: - Enums

export type WeightUnit = 'lbs' | 'kg';
export type DistanceUnit = 'meters' | 'km' | 'miles' | 'feet' | 'yards';
export type GroupType = 'superset' | 'section';

// MARK: - Parse Result Types

export interface ParseResult {
  success: boolean;
  data: WorkoutPlan | null;
  errors: string[];
  warnings: string[];
  /**
   * Machine-applicable corrections for diagnostics with an unambiguous repair
   * (currently MALFORMED_HEADER, e.g. `#push day` → `# push day`). Mirrors the
   * iOS parser's `LMWFParseResult.fixes` (GH #472).
   */
  fixes: QuickFix[];
}

/** One line-level correction the parser can offer for a diagnostic. */
export interface QuickFix {
  /** 1-based line in the document with CRLF/CR normalized to LF. */
  line: number;
  /** Trimmed text currently on `line`; the fix applies only while it still matches. */
  original: string;
  /** The full corrected line (without the original's indentation). */
  replacement: string;
}

export interface ParseError {
  line: number;
  message: string;
  code: string;
}

export interface ParseWarning {
  line: number;
  message: string;
  code: string;
}

// MARK: - Data Types

export interface WorkoutPlan {
  id: string;
  name: string;
  description: string | null;
  tags: string[];
  defaultWeightUnit: WeightUnit | null;
  sourceMarkdown: string | null;
  createdAt: string;
  updatedAt: string;
  isFavorite: boolean;
  exercises: PlannedExercise[];
}

export interface PlannedExercise {
  id: string;
  workoutPlanId: string;
  exerciseName: string;
  orderIndex: number;
  notes: string | null;
  equipmentType: string | null;
  groupType: GroupType | null;
  groupName: string | null;
  parentExerciseId: string | null;
  sets: PlannedSet[];
}

export interface PlannedSet {
  id: string;
  plannedExerciseId: string;
  orderIndex: number;
  targetWeight: number | null;
  targetWeightUnit: WeightUnit | null;
  targetReps: number | null;
  targetTime: number | null;
  targetDistance: number | null;
  targetDistanceUnit: DistanceUnit | null;
  targetRpe: number | null;
  restSeconds: number | null;
  tempo: string | null;
  isDropset: boolean;
  isPerSide: boolean;
  isAmrap: boolean;
  notes: string | null;
}

// MARK: - Internal Parse Types

export interface ParsedLine {
  lineNumber: number;
  raw: string;
  trimmed: string;
  headerLevel: number | null;
  headerText: string | null;
  isList: boolean;
  listContent: string | null;
  isMetadata: boolean;
  metadataKey: string | null;
  metadataValue: string | null;
}

export interface ParseContext {
  lines: ParsedLine[];
  currentIndex: number;
  workoutHeaderLevel: number | null;
  exerciseHeaderLevel: number | null;
  errors: ParseError[];
  warnings: ParseWarning[];
  fixes: QuickFix[];
  /** Line numbers of `@rest:` lines consumed as an exercise-level default rest. */
  exerciseRestDefaultLines: Set<number>;
}

export interface ParsedSet {
  weight?: number | null;
  weightUnit?: WeightUnit | null;
  reps?: number | null;
  time?: number | null;
  distance?: number | null;
  distanceUnit?: DistanceUnit | null;
  isAmrap?: boolean | null;
  rpe?: number | null;
  rest?: number | null;
  tempo?: string | null;
  isDropset?: boolean | null;
  isPerSide?: boolean | null;
  notes?: string | null;
}

export interface WorkoutSection {
  name: string;
  tags: string[];
  defaultWeightUnit: WeightUnit | null;
  notes: string | null;
}

export type ExerciseBlockResult =
  | { type: 'single'; exercise: PlannedExercise }
  | { type: 'group'; exercises: PlannedExercise[] }
  | { type: 'none' };
