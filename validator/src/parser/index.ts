import { randomUUID } from 'crypto';
import type {
  ParseResult,
  ParseError,
  ParseWarning,
  ParsedLine,
  ParseContext,
  ParsedSet,
  WorkoutSection,
  WorkoutPlan,
  PlannedExercise,
  PlannedSet,
  WeightUnit,
  DistanceUnit,
  GroupType,
  ExerciseBlockResult,
} from './types.js';

export type { ParseResult, WorkoutPlan, PlannedExercise, PlannedSet, WeightUnit, DistanceUnit, GroupType } from './types.js';

// MARK: - Public API

export function parseWorkout(markdown: string): ParseResult {
  const context: ParseContext = {
    lines: preprocessLines(markdown),
    currentIndex: 0,
    workoutHeaderLevel: null,
    exerciseHeaderLevel: null,
    errors: [],
    warnings: [],
  };
  const workoutId = generateId();

  // Find workout header
  const workoutHeaderLine = findWorkoutHeader(context);
  if (!workoutHeaderLine) {
    return {
      success: false,
      data: null,
      errors: ['No workout header found. Must have a header (# Workout Name) with exercises below it.'],
      warnings: [],
    };
  }

  // Parse workout metadata and notes
  const section = parseWorkoutSection(context, workoutHeaderLine);

  // Parse exercises
  let exercises = parseExercises(context, workoutId);

  // Apply default weight unit to sets that have a weight but no explicit unit
  if (section.defaultWeightUnit) {
    for (const exercise of exercises) {
      for (const set of exercise.sets) {
        if (set.targetWeight != null && set.targetWeightUnit == null) {
          set.targetWeightUnit = section.defaultWeightUnit;
        }
      }
    }
  }

  if (exercises.length === 0) {
    context.errors.push({
      line: workoutHeaderLine.lineNumber,
      message: 'Workout must contain at least one exercise',
      code: 'NO_EXERCISES',
    });
  }

  // Check for critical errors
  if (context.errors.length > 0) {
    return {
      success: false,
      data: null,
      errors: context.errors.map((e) => `Line ${e.line}: ${e.message}`),
      warnings: context.warnings.map((w) => `Line ${w.line}: ${w.message}`),
    };
  }

  const now = new Date().toISOString();
  // Check for duplicate exercise names
  const seenExerciseNames = new Map<string, number>();
  for (const exercise of exercises) {
    if (exercise.sets.length === 0) continue; // Skip group containers (sections/supersets with no sets)
    const lowerName = exercise.exerciseName.toLowerCase();
    if (seenExerciseNames.has(lowerName)) {
      context.warnings.push({
        line: 0,
        message: `Duplicate exercise name: '${exercise.exerciseName}'. Consider merging or renaming.`,
        code: 'DUPLICATE_EXERCISE_NAME',
      });
    } else {
      seenExerciseNames.set(lowerName, 0);
    }
  }

  const workout: WorkoutPlan = {
    id: workoutId,
    name: section.name,
    description: section.notes,
    tags: section.tags,
    defaultWeightUnit: section.defaultWeightUnit,
    sourceMarkdown: markdown,
    createdAt: now,
    updatedAt: now,
    isFavorite: false,
    exercises,
  };

  return {
    success: true,
    data: workout,
    errors: [],
    warnings: context.warnings.map((w) => `Line ${w.line}: ${w.message}`),
  };
}

// MARK: - ID Generation

function generateId(): string {
  return randomUUID();
}

// MARK: - Line Preprocessing

function preprocessLines(markdown: string): ParsedLine[] {
  // Normalize line endings (CRLF -> LF, CR -> LF)
  const normalized = markdown.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  const rawLines = normalized.split('\n');

  const headerRegex = /^(#{1,6})\s+(.+)$/;
  const listRegex = /^-\s+(.+)$/;
  const metadataRegex = /^@(\w+):\s*(.+)$/;

  return rawLines.map((raw, index) => {
    const trimmed = raw.trim();
    const lineNumber = index + 1;

    // Parse header
    const headerMatch = trimmed.match(headerRegex);
    if (headerMatch) {
      return {
        lineNumber,
        raw,
        trimmed,
        headerLevel: headerMatch[1].length,
        headerText: headerMatch[2].trim(),
        isList: false,
        listContent: null,
        isMetadata: false,
        metadataKey: null,
        metadataValue: null,
      };
    }

    // Parse list item
    const listMatch = trimmed.match(listRegex);
    if (listMatch) {
      return {
        lineNumber,
        raw,
        trimmed,
        headerLevel: null,
        headerText: null,
        isList: true,
        listContent: listMatch[1].trim(),
        isMetadata: false,
        metadataKey: null,
        metadataValue: null,
      };
    }

    // Parse metadata
    const metadataMatch = trimmed.match(metadataRegex);
    if (metadataMatch) {
      return {
        lineNumber,
        raw,
        trimmed,
        headerLevel: null,
        headerText: null,
        isList: false,
        listContent: null,
        isMetadata: true,
        metadataKey: metadataMatch[1].toLowerCase(),
        metadataValue: metadataMatch[2].trim(),
      };
    }

    // Regular text
    return {
      lineNumber,
      raw,
      trimmed,
      headerLevel: null,
      headerText: null,
      isList: false,
      listContent: null,
      isMetadata: false,
      metadataKey: null,
      metadataValue: null,
    };
  });
}

// MARK: - Workout Header Detection

function findWorkoutHeader(context: ParseContext): ParsedLine | null {
  for (let i = 0; i < context.lines.length; i++) {
    const line = context.lines[i];
    if (line.headerLevel != null && line.headerText != null) {
      if (hasChildExercises(context, i, line.headerLevel)) {
        context.workoutHeaderLevel = line.headerLevel;
        context.exerciseHeaderLevel = line.headerLevel + 1;
        context.currentIndex = i;
        return line;
      }
    }
  }
  return null;
}

function hasChildExercises(context: ParseContext, headerIndex: number, headerLevel: number): boolean {
  const exerciseLevel = headerLevel + 1;

  for (let i = headerIndex + 1; i < context.lines.length; i++) {
    const line = context.lines[i];

    // Stop if we hit a header at same or higher level
    if (line.headerLevel != null && line.headerLevel <= headerLevel) {
      break;
    }

    // Check if this is an exercise header (one level below workout)
    if (line.headerLevel === exerciseLevel) {
      if (hasSetsBelowHeader(context, i, exerciseLevel)) {
        return true;
      }
    }
  }

  return false;
}

function hasSetsBelowHeader(context: ParseContext, headerIndex: number, headerLevel: number): boolean {
  for (let i = headerIndex + 1; i < context.lines.length; i++) {
    const line = context.lines[i];

    // Stop if we hit a header at same or higher level
    if (line.headerLevel != null && line.headerLevel <= headerLevel) {
      break;
    }

    // Found a set
    if (line.isList) {
      return true;
    }

    // Check nested headers (for supersets/sections)
    if (line.headerLevel != null && line.headerLevel > headerLevel) {
      if (hasSetsBelowHeader(context, i, line.headerLevel)) {
        return true;
      }
    }
  }

  return false;
}

// MARK: - Workout Section Parsing

function parseWorkoutSection(context: ParseContext, headerLine: ParsedLine): WorkoutSection {
  const name = headerLine.headerText ?? '';
  let tags: string[] = [];
  let defaultWeightUnit: WeightUnit | null = null;
  const noteLines: string[] = [];

  // Move past header
  context.currentIndex += 1;

  // Collect metadata and notes until we hit an exercise header
  while (context.currentIndex < context.lines.length) {
    const line = context.lines[context.currentIndex];

    // Stop at exercise header
    if (line.headerLevel === context.exerciseHeaderLevel) {
      break;
    }

    // Stop at headers higher than workout level
    if (line.headerLevel != null && context.workoutHeaderLevel != null && line.headerLevel <= context.workoutHeaderLevel) {
      break;
    }

    // Parse metadata
    if (line.isMetadata) {
      if (line.metadataKey === 'tags') {
        tags = parseTagsMetadata(line.metadataValue ?? '');
      } else if (line.metadataKey === 'units') {
        const unit = parseUnitsMetadata(line.metadataValue ?? '', context, line.lineNumber);
        if (unit) {
          defaultWeightUnit = unit;
        }
      }
      // Ignore unknown metadata (forward compatible)
    } else if (line.trimmed.length > 0) {
      // Collect freeform notes (non-empty, non-metadata lines)
      noteLines.push(line.trimmed);
    }

    context.currentIndex += 1;
  }

  const notes = noteLines.length === 0 ? null : noteLines.join('\n');

  // Detect list-shaped content in the workout description.
  // Triggers on: bullet-prefixed lines (- or *), numbered lists (1., 1)), or
  // lines with 3+ commas (4+ comma-separated items). Neutral warning — the
  // agent decides whether the list is intentional prose or misplaced structure.
  if (notes && notes.length >= 20) {
    const listLine = findListShapedLine(noteLines);
    if (listLine) {
      const preview = listLine.length > 80 ? `${listLine.slice(0, 77)}...` : listLine;
      context.warnings.push({
        line: headerLine.lineNumber,
        message: `Workout description contains list-shaped content ("${preview}"). Only structured exercises are tracked — freeform description text is not.`,
        code: 'DESCRIPTION_CONTAINS_LIST',
      });
    }
  }

  return {
    name,
    tags,
    defaultWeightUnit,
    notes,
  };
}

/// Returns the first line that looks list-shaped, or null if none.
function findListShapedLine(lines: string[]): string | null {
  for (const line of lines) {
    // Bullet list: starts with `- ` or `* `
    if (/^[-*]\s+/.test(line)) return line;
    // Numbered list: `1.` or `1)` followed by space
    if (/^\d+[.)]\s+/.test(line)) return line;
    // 3+ commas (4+ items) on a single line
    if ((line.match(/,/g) || []).length >= 3) return line;
  }
  return null;
}

function parseTagsMetadata(value: string): string[] {
  return value
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

function parseUnitsMetadata(value: string, context: ParseContext, lineNumber: number): WeightUnit | null {
  const normalized = value.toLowerCase().trim();
  switch (normalized) {
    case 'lbs':
    case 'lb':
      return 'lbs';
    case 'kg':
    case 'kgs':
      return 'kg';
    default:
      context.errors.push({
        line: lineNumber,
        message: `Invalid @units value "${value}". Must be "lbs" or "kg"`,
        code: 'INVALID_UNITS',
      });
      return null;
  }
}

// MARK: - Exercise Parsing

function parseExercises(context: ParseContext, workoutPlanId: string): PlannedExercise[] {
  const exercises: PlannedExercise[] = [];
  let orderIndex = 0;

  // Track which blocks are singles (exercises) vs groups (sections/supersets) for mixed-level warning
  let firstSingleLine: number | null = null;
  let firstGroupLine: number | null = null;
  let firstSingleName: string | null = null;
  let firstGroupName: string | null = null;

  while (context.currentIndex < context.lines.length) {
    const line = context.lines[context.currentIndex];

    // Stop at headers at or above workout level
    if (line.headerLevel != null && context.workoutHeaderLevel != null && line.headerLevel <= context.workoutHeaderLevel) {
      break;
    }

    // Parse exercise at expected level
    if (line.headerLevel === context.exerciseHeaderLevel) {
      const blockLineNumber = line.lineNumber;
      const blockHeaderText = line.headerText;
      const result = parseExerciseBlock(context, workoutPlanId, orderIndex);
      switch (result.type) {
        case 'single':
          exercises.push(result.exercise);
          orderIndex += 1;
          if (firstSingleLine == null) {
            firstSingleLine = blockLineNumber;
            firstSingleName = result.exercise.exerciseName;
          }
          break;
        case 'group':
          exercises.push(...result.exercises);
          orderIndex += result.exercises.length;
          if (firstGroupLine == null) {
            firstGroupLine = blockLineNumber;
            firstGroupName = blockHeaderText ?? null;
          }
          break;
        case 'none':
          break;
      }
    } else {
      context.currentIndex += 1;
    }
  }

  // Warn if both standalone exercises and sections/supersets exist at the same heading level
  if (firstSingleLine != null && firstGroupLine != null) {
    const groupExample = firstGroupName ?? 'a section';
    const singleExample = firstSingleName ?? 'an exercise';
    context.warnings.push({
      line: Math.min(firstSingleLine, firstGroupLine),
      message:
        `Inconsistent nesting: some entries at the section level are grouping headers ` +
        `containing nested exercises (e.g. '${groupExample}') while others are standalone ` +
        `exercises (e.g. '${singleExample}'). Either use sections consistently throughout — ` +
        `wrap all exercise groups in named sections with exercises nested one level deeper ` +
        `(e.g. Warm-Up → Arm Circles, Main Workout → Bench Press, Cool-Down → Doorway Stretch) — ` +
        `or use a flat structure with all exercises at the same level. Structure is determined ` +
        `by relative nesting depth, not specific heading levels.`,
      code: 'INCONSISTENT_NESTING',
    });
  }

  return exercises;
}

function parseExerciseBlock(
  context: ParseContext,
  workoutPlanId: string,
  orderIndex: number
): ExerciseBlockResult {
  const headerLine = context.lines[context.currentIndex];
  const headerLevel = headerLine.headerLevel;
  const exerciseName = headerLine.headerText;

  if (headerLevel == null || exerciseName == null) {
    context.currentIndex += 1;
    return { type: 'none' };
  }

  const exerciseId = generateId();

  // Check if this is a superset or section (has nested headers)
  const isSuperset = exerciseName.toLowerCase().includes('superset');
  const hasNested = checkForNestedHeaders(context, context.currentIndex, headerLevel);

  // If it has nested headers, it's either a superset or section
  if (hasNested) {
    const grouped = parseGroupedExercises(context, workoutPlanId, orderIndex, exerciseName, isSuperset);
    return { type: 'group', exercises: grouped };
  }

  // Regular exercise (no nested headers)
  context.currentIndex += 1;

  // Parse metadata and notes
  const { equipmentType, notes } = parseExerciseMetadata(context, headerLevel);

  // Parse sets
  let sets = parseSets(context, headerLevel, exerciseId);

  // Auto-detect per-side keywords in exercise notes
  const perSideKeywords = ['per side', 'per leg', 'per arm', 'each side', 'each leg', 'each arm', 'each'];
  if (notes) {
    const hasPerSideKeyword = perSideKeywords.some(
      (kw) => notes.toLowerCase().includes(kw.toLowerCase())
    );
    if (hasPerSideKeyword) {
      sets = sets.map((set) => {
        if (set.targetTime != null && !set.isPerSide) {
          return { ...set, isPerSide: true };
        }
        return set;
      });
    }
  }

  if (sets.length === 0) {
    context.errors.push({
      line: headerLine.lineNumber,
      message: `Exercise "${exerciseName}" has no sets`,
      code: 'NO_SETS',
    });
  }

  const exercise: PlannedExercise = {
    id: exerciseId,
    workoutPlanId,
    exerciseName,
    orderIndex,
    notes,
    equipmentType,
    groupType: null,
    groupName: null,
    parentExerciseId: null,
    sets,
  };

  return { type: 'single', exercise };
}

function checkForNestedHeaders(context: ParseContext, headerIndex: number, headerLevel: number): boolean {
  for (let i = headerIndex + 1; i < context.lines.length; i++) {
    const line = context.lines[i];

    // Stop at same or higher level header
    if (line.headerLevel != null && line.headerLevel <= headerLevel) {
      break;
    }

    // Found nested header at any level below parent
    if (line.headerLevel != null && line.headerLevel > headerLevel) {
      return true;
    }
  }
  return false;
}

function findChildExerciseLevel(context: ParseContext, startIndex: number, parentLevel: number): number | null {
  for (let i = startIndex; i < context.lines.length; i++) {
    const line = context.lines[i];

    // Stop at same or higher level header
    if (line.headerLevel != null && line.headerLevel <= parentLevel) {
      break;
    }

    // Check if this header has sets below it
    if (line.headerLevel != null && line.headerLevel > parentLevel) {
      if (hasSetsBelowHeader(context, i, line.headerLevel)) {
        return line.headerLevel;
      }
    }
  }
  return null;
}

function parseGroupedExercises(
  context: ParseContext,
  workoutPlanId: string,
  orderIndex: number,
  groupName: string,
  isSuperset: boolean
): PlannedExercise[] {
  const headerLine = context.lines[context.currentIndex];
  const parentId = generateId();
  const groupType: GroupType = isSuperset ? 'superset' : 'section';

  // Create parent exercise (no sets, just a grouping container)
  const parentExercise: PlannedExercise = {
    id: parentId,
    workoutPlanId,
    exerciseName: groupName,
    orderIndex,
    notes: null,
    equipmentType: null,
    groupType,
    groupName,
    parentExerciseId: null,
    sets: [],
  };

  context.currentIndex += 1;

  // Find the first child header level that contains exercises (sets)
  const childExerciseLevel = findChildExerciseLevel(context, context.currentIndex, headerLine.headerLevel!);

  // Parse child exercises
  const childExercises: PlannedExercise[] = [];
  let childOrderIndex = 0;

  while (context.currentIndex < context.lines.length) {
    const line = context.lines[context.currentIndex];

    // Stop at same or higher level header
    if (line.headerLevel != null && line.headerLevel <= headerLine.headerLevel!) {
      break;
    }

    // Parse child exercise at the determined child level
    if (childExerciseLevel != null && line.headerLevel === childExerciseLevel) {
      const result = parseExerciseBlock(context, workoutPlanId, orderIndex + childOrderIndex + 1);
      switch (result.type) {
        case 'single': {
          const exercise = { ...result.exercise };
          if (exercise.parentExerciseId == null) {
            exercise.parentExerciseId = parentId;
          }
          if (exercise.groupType == null) {
            exercise.groupType = groupType;
            exercise.groupName = groupName;
          }
          childExercises.push(exercise);
          childOrderIndex += 1;
          break;
        }
        case 'group': {
          for (const ex of result.exercises) {
            const exercise = { ...ex };
            if (exercise.parentExerciseId == null) {
              exercise.parentExerciseId = parentId;
            }
            if (exercise.groupType !== 'superset' || exercise.sets.length === 0) {
              if (exercise.groupType == null) {
                exercise.groupType = groupType;
                exercise.groupName = groupName;
              }
            }
            childExercises.push(exercise);
            childOrderIndex += 1;
          }
          break;
        }
        case 'none':
          break;
      }
    } else {
      context.currentIndex += 1;
    }
  }

  return [parentExercise, ...childExercises];
}

function parseExerciseMetadata(
  context: ParseContext,
  exerciseHeaderLevel: number
): { equipmentType: string | null; notes: string | null } {
  let equipmentType: string | null = null;
  const noteLines: string[] = [];

  while (context.currentIndex < context.lines.length) {
    const line = context.lines[context.currentIndex];

    // Stop at headers at or above exercise level
    if (line.headerLevel != null && line.headerLevel <= exerciseHeaderLevel) {
      break;
    }

    // Stop at sets (list items)
    if (line.isList) {
      break;
    }

    // Parse metadata
    if (line.isMetadata) {
      if (line.metadataKey === 'type') {
        equipmentType = line.metadataValue;
      }
      // Ignore unknown metadata (forward compatible)
      context.currentIndex += 1;
    } else if (line.trimmed.length > 0) {
      noteLines.push(line.trimmed);
      context.currentIndex += 1;
    } else {
      context.currentIndex += 1;
    }
  }

  return {
    equipmentType,
    notes: noteLines.length === 0 ? null : noteLines.join('\n'),
  };
}

// MARK: - Set Parsing

function parseSets(context: ParseContext, exerciseHeaderLevel: number, exerciseId: string): PlannedSet[] {
  const sets: PlannedSet[] = [];
  let orderIndex = 0;

  while (context.currentIndex < context.lines.length) {
    const line = context.lines[context.currentIndex];

    // Stop at headers at or above exercise level
    if (line.headerLevel != null && line.headerLevel <= exerciseHeaderLevel) {
      break;
    }

    // Parse set (list item)
    if (line.isList && line.listContent) {
      const parsedSet = parseSetLine(line.listContent, context, line.lineNumber);
      if (parsedSet) {
        sets.push({
          id: generateId(),
          plannedExerciseId: exerciseId,
          orderIndex,
          targetWeight: parsedSet.weight ?? null,
          targetWeightUnit: parsedSet.weightUnit ?? null,
          targetReps: parsedSet.reps ?? null,
          targetTime: parsedSet.time ?? null,
          targetDistance: parsedSet.distance ?? null,
          targetDistanceUnit: parsedSet.distanceUnit ?? null,
          targetRpe: parsedSet.rpe != null ? roundRpe(parsedSet.rpe, context, line.lineNumber) : null,
          restSeconds: parsedSet.rest ?? null,
          tempo: parsedSet.tempo ?? null,
          isDropset: parsedSet.isDropset ?? false,
          isPerSide: parsedSet.isPerSide ?? false,
          isAmrap: parsedSet.isAmrap ?? false,
          notes: parsedSet.notes ?? null,
        });
        orderIndex += 1;
      }
      context.currentIndex += 1;
    } else {
      context.currentIndex += 1;
    }
  }

  return sets;
}

function roundRpe(value: number, context: ParseContext, lineNumber: number): number {
  const rounded = Math.round(value);
  const clamped = Math.max(1, Math.min(10, rounded));
  if (clamped !== value) {
    context.warnings.push({
      line: lineNumber,
      message: `RPE rounded to nearest integer (${value} → ${clamped})`,
      code: 'RPE_ROUNDED',
    });
  }
  return clamped;
}

function parseSetLine(content: string, context: ParseContext, lineNumber: number): ParsedSet | null {
  // Split on @ to separate main content from modifiers
  const parts = content.split('@');
  const mainPart = parts[0].trim();
  const modifierParts = parts.slice(1);

  // Parse modifiers and extract trailing text
  const { modifiers, trailingText: modifierTrailingText } = parseModifiersAndTrailingText(
    modifierParts,
    context,
    lineNumber
  );

  // Parse main set content
  const mainResult = parseMainSetContent(mainPart, context, lineNumber);
  if (!mainResult) {
    return null;
  }

  const { set: setResult, trailingText: mainTrailingText } = mainResult;

  // Combine trailing text
  const combinedParts = [mainTrailingText, modifierTrailingText].filter((t): t is string => t != null);
  const combined = combinedParts.join(' ').trim();

  // Merge modifiers into set
  const result: ParsedSet = { ...setResult };
  if (modifiers.rpe != null) result.rpe = modifiers.rpe;
  if (modifiers.rest != null) result.rest = modifiers.rest;
  if (modifiers.tempo != null) result.tempo = modifiers.tempo;
  if (modifiers.isDropset != null) result.isDropset = modifiers.isDropset;
  if (modifiers.isPerSide != null) result.isPerSide = modifiers.isPerSide;
  if (combined.length > 0) result.notes = combined;

  // Auto-detect per-side keywords in set-line trailing text for timed sets
  if (result.time != null && result.isPerSide !== true) {
    const perSideKeywords = ['per side', 'per leg', 'per arm', 'each side', 'each leg', 'each arm', 'each'];
    const textToCheck = combined;
    if (textToCheck.length > 0) {
      const hasKeyword = perSideKeywords.some((kw) => textToCheck.toLowerCase().includes(kw.toLowerCase()));
      if (hasKeyword) {
        result.isPerSide = true;
        // Strip the per-side keyword from notes since it's now conveyed by the flag
        let cleaned = textToCheck;
        for (const keyword of perSideKeywords) {
          const regex = new RegExp(keyword, 'i');
          cleaned = cleaned.replace(regex, '');
        }
        cleaned = cleaned.trim();
        result.notes = cleaned.length === 0 ? null : cleaned;
      }
    }
  }

  return result;
}

function parseMainSetContent(
  content: string,
  context: ParseContext,
  lineNumber: number
): { set: ParsedSet; trailingText: string | null } | null {
  const original = content.trim();
  const trimmedLower = original.toLowerCase();

  // Reject standalone AMRAP — AMRAP must modify a weight (e.g., "135 x AMRAP", "bw x AMRAP")
  if (trimmedLower === 'amrap') {
    context.errors.push({
      line: lineNumber,
      message: 'Standalone "AMRAP" is not valid. AMRAP must be used with a weight (e.g., "135 x AMRAP" or "bw x AMRAP")',
      code: 'STANDALONE_AMRAP',
    });
    return null;
  }

  // Pattern 1: weight unit x reps/time (e.g., "225 lbs x 5", "45 lbs x 60s")
  const pattern1 = /^(\d+(?:\.\d+)?)\s*(lbs?|kgs?|kg|bw)?\s*(?:x|for)\s*(\d+|amrap)\s*(reps?|s|sec|m|min)?(?=\s|$)\s*(.*)$/i;

  // Pattern 2: bodyweight x|for reps/time (e.g., "x 10", "bw x 12", "bw for 60s")
  const pattern2 = /^(?:(bw|x)\s*)?(?:x|for)\s*(\d+|amrap)\s*(reps?|s|sec|m|min)?(?=\s|$)\s*(.*)$/i;

  // Pattern D: distance (e.g., "200 meters", "0.5 km", "1 mile", "400 yd")
  const distancePattern = /^(\d+(?:\.\d+)?)\s*(meters?|km|miles?|mi|feet|foot|ft|yards?|yd)(?=\s|$)\s*(.*)$/i;
  const distanceMatch = original.match(distancePattern);
  if (distanceMatch) {
    const distance = parseFloat(distanceMatch[1]);
    const unitStr = distanceMatch[2];
    const trailing = distanceMatch[3]?.trim() || null;

    if (distance <= 0) {
      context.errors.push({ line: lineNumber, message: 'Distance must be positive', code: 'INVALID_DISTANCE' });
      return null;
    }

    return {
      set: {
        distance,
        distanceUnit: normalizeDistanceUnit(unitStr),
      },
      trailingText: trailing && trailing.length > 0 ? trailing : null,
    };
  }

  // Pattern 3: single number (e.g., "10" = bodyweight reps, "60s" = time)
  const pattern3 = /^(\d+)\s*(s|sec|m|min)?(?=\s|$)\s*(.*)$/i;

  // Try pattern 1
  let match = original.match(pattern1);
  if (match) {
    const weightStr = match[1];
    const unitStr = match[2] || null;
    const repsOrTimeStr = match[3].toLowerCase();
    const repsUnitStr = match[4] || null;
    const trailing = match[5]?.trim() || null;

    const weight = parseFloat(weightStr);
    const weightUnit = normalizeWeightUnit(unitStr);

    if (weight < 0) {
      context.errors.push({ line: lineNumber, message: 'Weight cannot be negative', code: 'NEGATIVE_WEIGHT' });
      return null;
    }

    // Check if it's AMRAP
    if (repsOrTimeStr === 'amrap') {
      const isBW = unitStr?.toLowerCase() === 'bw';
      return {
        set: {
          weight: isBW ? null : weight,
          weightUnit: isBW ? null : weightUnit,
          isAmrap: true,
        },
        trailingText: trailing && trailing.length > 0 ? trailing : null,
      };
    }

    const value = parseInt(repsOrTimeStr, 10);
    if (value <= 0) {
      context.errors.push({ line: lineNumber, message: 'Reps/time must be positive', code: 'INVALID_REPS_TIME' });
      return null;
    }

    const isTime = repsUnitStr
      ? repsUnitStr.toLowerCase().startsWith('s') || repsUnitStr.toLowerCase().startsWith('m')
      : false;

    const isBW = unitStr?.toLowerCase() === 'bw';

    if (isTime) {
      const seconds = normalizeTimeToSeconds(value, repsUnitStr);
      return {
        set: {
          weight: isBW ? null : weight,
          weightUnit: isBW ? null : (weightUnit ?? null),
          time: seconds,
        },
        trailingText: trailing && trailing.length > 0 ? trailing : null,
      };
    } else {
      if (value > 100) {
        context.warnings.push({
          line: lineNumber,
          message: `Very high rep count (${value}). Double-check for typos.`,
          code: 'HIGH_REPS',
        });
      }
      return {
        set: {
          weight: isBW ? null : weight,
          weightUnit: isBW ? null : (weightUnit ?? null),
          reps: value,
        },
        trailingText: trailing && trailing.length > 0 ? trailing : null,
      };
    }
  }

  // Try pattern 2
  match = original.match(pattern2);
  if (match) {
    const repsOrTimeStr = match[2].toLowerCase();
    const repsUnitStr = match[3] || null;
    const trailing = match[4]?.trim() || null;

    if (repsOrTimeStr === 'amrap') {
      return { set: { isAmrap: true }, trailingText: trailing && trailing.length > 0 ? trailing : null };
    }

    const value = parseInt(repsOrTimeStr, 10);
    if (value <= 0) {
      context.errors.push({ line: lineNumber, message: 'Reps/time must be positive', code: 'INVALID_REPS_TIME' });
      return null;
    }

    const isTime = repsUnitStr
      ? repsUnitStr.toLowerCase().startsWith('s') || repsUnitStr.toLowerCase().startsWith('m')
      : false;

    if (isTime) {
      const seconds = normalizeTimeToSeconds(value, repsUnitStr);
      return { set: { time: seconds }, trailingText: trailing && trailing.length > 0 ? trailing : null };
    } else {
      if (value > 100) {
        context.warnings.push({
          line: lineNumber,
          message: `Very high rep count (${value}). Double-check for typos.`,
          code: 'HIGH_REPS',
        });
      }
      return { set: { reps: value }, trailingText: trailing && trailing.length > 0 ? trailing : null };
    }
  }

  // Try pattern 3
  match = original.match(pattern3);
  if (match) {
    const valueStr = match[1];
    const unitStr = match[2] || null;
    const trailing = match[3]?.trim() || null;

    // Reject "135 lbs" or "100 kg" — weight unit without reps/time is incomplete
    if (!unitStr && trailing) {
      const trailingLower = trailing.toLowerCase();
      if (/^(lbs?|kgs?|kg)\b/.test(trailingLower)) {
        context.errors.push({
          line: lineNumber,
          message: `Incomplete set: "${content}". Weight with unit requires reps (x 5) or time (x 60s)`,
          code: 'INCOMPLETE_SET',
        });
        return null;
      }
    }

    const value = parseInt(valueStr, 10);
    if (value <= 0) {
      context.errors.push({ line: lineNumber, message: 'Reps/time must be positive', code: 'INVALID_REPS_TIME' });
      return null;
    }

    const isTime = unitStr
      ? unitStr.toLowerCase().startsWith('s') || unitStr.toLowerCase().startsWith('m')
      : false;

    if (isTime) {
      const seconds = normalizeTimeToSeconds(value, unitStr);
      return { set: { time: seconds }, trailingText: trailing && trailing.length > 0 ? trailing : null };
    } else {
      if (value > 100) {
        context.warnings.push({
          line: lineNumber,
          message: `Very high rep count (${value}). Double-check for typos.`,
          code: 'HIGH_REPS',
        });
      }
      return { set: { reps: value }, trailingText: trailing && trailing.length > 0 ? trailing : null };
    }
  }

  // Failed to parse
  context.errors.push({
    line: lineNumber,
    message: `Invalid set format: "${content}". Expected format: "weight unit x reps" or "time" or "AMRAP"`,
    code: 'INVALID_SET_FORMAT',
  });
  return null;
}

// MARK: - Helpers

function normalizeWeightUnit(unit: string | null): WeightUnit | null {
  if (!unit) return null;
  const normalized = unit.toLowerCase().trim();
  switch (normalized) {
    case 'lb':
    case 'lbs':
      return 'lbs';
    case 'kg':
    case 'kgs':
      return 'kg';
    case 'bw':
      return null; // bodyweight
    default:
      return null;
  }
}

function normalizeDistanceUnit(unit: string): DistanceUnit {
  const lower = unit.toLowerCase();
  switch (lower) {
    case 'meters':
    case 'meter':
      return 'meters';
    case 'km':
      return 'km';
    case 'miles':
    case 'mile':
    case 'mi':
      return 'miles';
    case 'feet':
    case 'foot':
    case 'ft':
      return 'feet';
    case 'yards':
    case 'yard':
    case 'yd':
      return 'yards';
    default:
      return 'meters';
  }
}

function normalizeTimeToSeconds(value: number, unit: string | null): number {
  if (!unit) return value;
  if (unit.toLowerCase().startsWith('m')) {
    return value * 60;
  }
  return value;
}

function parseModifiersAndTrailingText(
  parts: string[],
  context: ParseContext,
  lineNumber: number
): { modifiers: ParsedSet; trailingText: string | null } {
  const modifiers: ParsedSet = {};
  const trailingTextParts: string[] = [];

  for (const part of parts) {
    const trimmed = part.trim();
    if (trimmed.length === 0) continue;

    const lowerTrimmed = trimmed.toLowerCase();

    // Check flag modifiers
    if (lowerTrimmed.startsWith('dropset')) {
      modifiers.isDropset = true;
      const trailing = trimmed.slice('dropset'.length).trim();
      if (trailing.length > 0) trailingTextParts.push(trailing);
      continue;
    }
    if (lowerTrimmed.startsWith('perside')) {
      modifiers.isPerSide = true;
      const trailing = trimmed.slice('perside'.length).trim();
      if (trailing.length > 0) trailingTextParts.push(trailing);
      continue;
    }
    if (lowerTrimmed.startsWith('amrap')) {
      const trailing = trimmed.slice('amrap'.length).trim();
      if (trailing.length > 0) trailingTextParts.push(trailing);
      context.warnings.push({
        line: lineNumber,
        message: `@amrap is not a modifier — express AMRAP via the rep value instead (e.g., "135 x AMRAP")`,
        code: 'DEPRECATED_AMRAP',
      });
      continue;
    }

    // Try to parse as key: value modifier
    const modifierMatch = trimmed.match(/^(\w+):\s*(.+)$/);
    if (!modifierMatch) {
      // Not a valid modifier, treat as trailing text
      trailingTextParts.push(trimmed);
      continue;
    }

    const key = modifierMatch[1].toLowerCase();
    const value = modifierMatch[2].trim();

    switch (key) {
      case 'rpe': {
        const rpeMatch = value.match(/^(\d+(?:\.\d+)?)\s*(.*)$/);
        if (rpeMatch) {
          const rpe = parseFloat(rpeMatch[1]);
          const remaining = rpeMatch[2]?.trim() || null;
          if (rpe < 1 || rpe > 10) {
            context.errors.push({
              line: lineNumber,
              message: `RPE must be between 1-10, got: ${rpeMatch[1]}`,
              code: 'INVALID_RPE',
            });
          } else {
            modifiers.rpe = rpe;
            if (remaining && remaining.length > 0) trailingTextParts.push(remaining);
            context.warnings.push({
              line: lineNumber,
              message: `@rpe is deprecated — use freeform notes instead`,
              code: 'DEPRECATED_RPE',
            });
          }
        } else {
          context.errors.push({
            line: lineNumber,
            message: `Invalid RPE format: ${value}`,
            code: 'INVALID_RPE',
          });
        }
        break;
      }

      case 'rest': {
        const restMatch = value.match(/^(\d+)\s*(s|sec|m|min)?\s*(.*)$/i);
        if (restMatch) {
          const numStr = restMatch[1];
          const unitStr = restMatch[2] || null;
          const remaining = restMatch[3]?.trim() || null;
          const restValue = `${numStr}${unitStr ?? ''}`;
          const rest = parseRestTime(restValue);
          if (rest != null) {
            if (rest < 10) {
              context.warnings.push({
                line: lineNumber,
                message: `Very short rest period (${rest}s). Double-check for typos.`,
                code: 'SHORT_REST',
              });
            }
            if (rest > 600) {
              context.warnings.push({
                line: lineNumber,
                message: `Very long rest period (${rest}s). Double-check for typos.`,
                code: 'LONG_REST',
              });
            }
            modifiers.rest = rest;
            if (remaining && remaining.length > 0) trailingTextParts.push(remaining);
          } else {
            context.errors.push({
              line: lineNumber,
              message: `Invalid rest time format: ${restValue}. Expected format: "180s" or "3m"`,
              code: 'INVALID_REST',
            });
          }
        } else {
          context.errors.push({
            line: lineNumber,
            message: `Invalid rest time format: ${value}. Expected format: "180s" or "3m"`,
            code: 'INVALID_REST',
          });
        }
        break;
      }

      case 'tempo': {
        const tempoMatch = value.match(/^(\d-\d-\d-\d)\s*(.*)$/);
        if (tempoMatch) {
          modifiers.tempo = tempoMatch[1];
          const remaining = tempoMatch[2]?.trim() || null;
          if (remaining && remaining.length > 0) trailingTextParts.push(remaining);
          context.warnings.push({
            line: lineNumber,
            message: `@tempo is deprecated — use freeform notes instead`,
            code: 'DEPRECATED_TEMPO',
          });
        } else {
          context.errors.push({
            line: lineNumber,
            message: `Invalid tempo format: ${value}. Expected format: "X-X-X-X" (e.g., "3-0-1-0")`,
            code: 'INVALID_TEMPO',
          });
        }
        break;
      }

      default: {
        // Unknown modifier
        context.warnings.push({
          line: lineNumber,
          message: `Unknown modifier: @${key}`,
          code: 'UNKNOWN_MODIFIER',
        });
        trailingTextParts.push(trimmed);
      }
    }
  }

  return {
    modifiers,
    trailingText: trailingTextParts.length === 0 ? null : trailingTextParts.join(' '),
  };
}

function parseRestTime(value: string): number | null {
  const match = value.match(/^(\d+)\s*(s|sec|m|min)?$/i);
  if (!match) return null;
  const num = parseInt(match[1], 10);
  const unit = match[2]?.toLowerCase() ?? 's';
  if (unit.startsWith('m')) {
    return num * 60;
  }
  return num;
}
