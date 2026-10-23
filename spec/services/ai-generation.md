# AI Workout Generation Service Specification

## Purpose

Generate personalized workout plans using a bring-your-own-key LLM provider: Anthropic, OpenAI, Gemini, or a self-hosted Ollama server. The provider layer is specified in `spec/services/ai-providers.md`. This combines user context (workout history, gym equipment, preferences) with a structured prompt to produce LMWF-formatted workout plans.

## Generation Paths

There are two user-facing paths for AI workout generation:

1. **In-app generation**: The user adds one or more provider keys in Settings, as an ordered list. The app calls the providers directly, trying keys in order until one succeeds, then parses the workout and presents it for review.
2. **Open in Claude**: The app assembles the same structured prompt, copies it to the clipboard, and opens Claude.ai in the browser. The user pastes the prompt, receives a workout in LMWF format, and imports the result back into the app.

## API Configuration

Endpoints, default models, token limits, the error mapping, and the ordered-fallback rules are all specified per provider in `spec/services/ai-providers.md`. Errors are translated into user-friendly messages that name the provider that failed.

## Context Assembly

The following data is gathered and included in the generation prompt:

- **Settings**: User's preferred weight unit, custom prompt instructions.
- **History**: Recent workout history, formatted in a compact abbreviated format.
- **Equipment**: Available equipment from the user's default gym.
- **Gym name**: The name of the user's default gym.

## Prompt Structure

The prompt is assembled in this order:

1. System role definition (strength coach persona).
2. User context block (history, gym, equipment, preferences).
3. Workout request (user's specific ask).
4. LMWF format specification with examples.
5. Output instructions (return only the markdown, no preamble).

## Validation Checks

The generated workout is validated before being presented to the user.

### Required (errors)

- Workout must have a name.
- Workout must have at least one exercise.

### Per Exercise

- Exercise name is required.
- Warning if exercise has no sets.

### Per Set

- Must have at least one of: weight, reps, or time.
- Warning if weight is specified without a unit.
- RPE must be in range 1-10 if specified.

### Volume

- Warning if total working sets are fewer than 8.
- Warning if total working sets exceed 40.

## Error Handling

- Parse failures from the AI response are surfaced through the standard parse result error mechanism.
- Validation issues are returned as warnings or errors, not thrown as exceptions.
