# Import Workout Flow

## Preconditions

- App is running and user is authenticated.
- For file share entry: a `.txt`, `.md`, or `.markdown` file is shared via iOS share sheet.
- For AI generation: optionally, one or more AI provider keys (Anthropic, OpenAI, Gemini, Ollama) are configured in Settings.

## Entry Points

1. **Home screen**: "Create Plan" button opens the import modal.
2. **File share**: `liftmark://` deep link from iOS share sheet opens the import modal with prefilled markdown.
3. **Workouts tab**: Navigation to import is available from the workouts list.

## Import Modal (app/modal/import.tsx)

The modal presents:

- Header with Cancel and Import buttons.
- AI Workout Prompt section (expandable, with copy button).
- "Generate with Claude" button (visible if API key is configured).
- "Open in Claude" button (visible if no API key is set or `showOpenInClaudeButton` is enabled).
- Markdown text input for pasting LMWF content.
- Quick guide section with format reference.

## Flow Steps

### Manual Import

1. User enters markdown into the text input (paste, type, or prefilled from file share).
2. User taps the **Import** button.
3. The markdown is parsed via `parseWorkout()`.
4. **Parse errors**: A "Parse Error" alert is shown. The user remains on the modal to correct the input.
5. **Warnings**: A "Warnings" alert is shown with Cancel and Continue options.
   - Cancel: user stays on the modal to edit.
   - Continue: proceeds to save.
6. **Success**: `savePlan()` stores the workout plan to the SQLite database. A "Success" alert is shown. The app navigates back to the previous screen.
7. **Cancel with unsaved text**: If the user taps Cancel while unsaved markdown text exists, a "Discard Changes" confirmation dialog is shown.

### AI Generation Sub-flow

1. User taps "Generate with Claude".
2. If no API key is configured, the user is prompted to add one in Settings.
3. The system builds a prompt from:
   - Base LMWF format template.
   - Equipment context from the default gym.
   - Recent workout history.
   - Custom prompt additions from settings.
4. `AIProviderService.generateWorkout(prompt:keys:)` is called with the user's ordered provider keys.
5. On success: the generated markdown populates the text input field. The user reviews, optionally edits, and then imports.
6. On failure: an error alert is shown describing the issue (rate limit, invalid key, server error, network error).

### File Import Sub-flow

1. iOS sends a `liftmark://` URL when a file is shared.
2. `fileImportService.isFileImportUrl()` validates the file extension (`.txt`, `.md`, `.markdown`).
3. `readSharedFile()` reads the file content (maximum 1MB).
4. The import modal opens with the `prefilledMarkdown` parameter populated.

## Variations

- **Empty input**: The Import button should be disabled or show a validation message if the markdown field is empty.
- **Large file**: Files exceeding 1MB are rejected during the file import sub-flow.
- **Unsupported file type**: Files with extensions other than `.txt`, `.md`, or `.markdown` are not handled by `isFileImportUrl()`.
- **Multiple parse warnings**: All warnings are displayed in the alert for user review before continuing.

## Error Handling

| Scenario | Behavior |
|---|---|
| Invalid LMWF markdown | Parse Error alert shown, user stays on modal |
| Parse warnings present | Warnings alert with Cancel/Continue options |
| AI generation fails (no API key) | Prompt to configure key in Settings |
| AI generation fails (network/server) | Error alert with description |
| AI generation fails (rate limit) | Error alert indicating rate limit |
| AI generation fails (invalid key) | Error alert indicating invalid API key |
| File too large (>1MB) | File import rejected |
| Unsupported file extension | URL not recognized as file import |
| Database save failure | Error alert shown |

## Postconditions

- A new workout plan is saved to the SQLite database.
- The new plan appears in the plan list on both the Home and Workouts screens.
- The import modal is dismissed.
