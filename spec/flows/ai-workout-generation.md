# AI Workout Generation Flow

## Preconditions

- The import modal is open.
- For Path A: At least one AI provider key (Anthropic, OpenAI, Gemini, or Ollama) that isn't marked invalid is configured in Settings.
- For Path B: No API key is configured, or the "Open in Claude" button is enabled.

## Path A: In-App Generation (API Key Configured)

### Flow Steps

1. User taps **"Generate with Claude"** in the import modal.
2. The system builds a generation prompt by gathering context:
   - `workoutGenerationService.buildWorkoutGenerationPrompt()` creates the structured prompt.
   - `gatherWorkoutGenerationContext()` pulls data from `settingsStore`, `gymStore`, `equipmentStore`, and `workoutHistoryService`.
3. The prompt includes:
   - LMWF format specification.
   - Available equipment from the default gym.
   - Workout history (last 5 sessions in compact format).
   - Custom prompt additions from user settings.
4. `AIProviderService.generateWorkout(prompt:keys:)` sends the prompt to the first usable key in the user's ordered list, falling back to the next key on failure (see `spec/services/ai-providers.md`).
   - Each key uses its own configured model, or the provider default.
   - Keys rejected with an auth error are marked `invalid`. Keys that succeed while `unverified` are marked `verified`.
5. On success: the generated LMWF markdown populates the text input field in the import modal.
6. The user reviews the generated workout, optionally edits it, and then proceeds with the standard import flow.

### Error Handling

| Scenario | Behavior |
|---|---|
| No API key configured | Generate button hidden; user is prompted to add a key in Settings |
| Invalid API key | Key marked invalid, next key tried; if none left, error names the provider |
| Several keys all fail | One error line per provider tried |
| Rate limit exceeded | Error alert indicating rate limit |
| Server error (5xx) | Error alert with server error description |
| Network error | Error alert indicating connectivity issue |
| Response parsing failure | Error alert shown |

## Path B: External Generation (No API Key)

### Flow Steps

1. User taps **"Open in Claude"** in the import modal.
2. The system copies the generation prompt to the clipboard.
3. The system opens `claude.ai` in the device's default browser.
4. The user pastes the prompt into the Claude conversation.
5. Claude generates a workout in LMWF format.
6. The user copies the generated LMWF markdown from Claude's response.
7. The user returns to the LiftMark app and pastes the markdown into the import modal's text input.
8. The user proceeds with the standard import flow.

## Prompt Construction

- `workoutGenerationService.buildWorkoutGenerationPrompt()` is the primary entry point for prompt assembly.
- `gatherWorkoutGenerationContext()` collects:
  - User context: workout history, available equipment, gym details, user preferences.
  - Workout request parameters from the user's input.
- The prompt is structured to produce valid LMWF markdown output that can be parsed by `parseWorkout()`.

## API Key Management

- Keys are stored in secure storage (Keychain), not in the SQLite database.
- Users add keys one at a time through an "Add Key" sheet: pick a provider, then enter the key (or, for Ollama, a server URL) and an optional model.
- On save, the format is checked offline, then the key is verified with the provider's **free** list-models endpoint. No tokens are spent.
- Key status is one of: `verified`, `unverified` (couldn't verify yet; checked on first use), or `invalid`.
- The list is ordered and the user can reorder it. Order sets which provider is tried first.

## Variations

- **No default gym configured**: Equipment context is omitted from the prompt.
- **No workout history**: History section is omitted from the prompt.
- **Custom prompt additions**: Additional user-defined instructions are appended to the prompt if configured in settings.
- **User edits generated output**: The user can freely modify the generated markdown before importing.
- **Regeneration**: The user can tap "Generate with Claude" again to replace the current markdown with a new generation.

## Error Handling Summary

| Scenario | Behavior |
|---|---|
| Clipboard write failure (Path B) | Error logged; user may need to manually copy |
| Browser open failure (Path B) | Error alert shown |
| Context gathering failure | Generation proceeds with available context; missing sections omitted |
| Generated markdown fails parsing | User sees parse errors in the standard import flow and can edit |

## Postconditions

- Generated LMWF markdown is present in the import modal's text input, ready for review and import.
- No data is saved to the database until the user completes the import flow.
- The generation prompt reflects current gym equipment, recent workout history, and user preferences.
