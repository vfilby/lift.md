# Import Workout Modal

## Purpose
Modal for importing workouts via LiftMark Workout Format (LMWF) markdown. Supports manual paste, AI-generated prompts (copy to clipboard or generate directly via the user's BYOK provider: Anthropic, OpenAI, Gemini, or Ollama), and file pre-fill from external imports (share sheet, "Open In", or `liftmark://` deep links).

## Route
`/modal/import` — Presented as a modal. Accepts optional `prefilledMarkdown` and `fileName` search params.

## External File Import (Share Target)

LiftMark registers as a handler for markdown (`.md`) and plain-text files. Users can share or "Open In" a `.md` file from Files, Safari, email, or any app that supports the iOS share sheet.

### Declared Document Types
- **UTTypes**: `net.daringfireball.markdown`, `public.plain-text`
- **Role**: Viewer
- **Handler Rank**: Alternate (does not claim ownership of `.md` files system-wide)
- **Open In Place**: `false` — the app reads a copy; the original file is not modified

### Flow
1. User taps "Share" or "Open In" on a `.md` file in another app
2. iOS presents LiftMark in the share sheet / "Open In" picker
3. LiftMark launches (or foregrounds) and receives a `file://` URL via `onOpenURL`
4. The app reads the file content using security-scoped resource access
5. The content is set as `pendingImportContent`, which triggers the Import Modal with the markdown pre-filled
6. User reviews, edits if needed, and taps Import

### Deep Links
- `liftmark:///path/to/file.md` — reads local file at the given path and pre-fills the import modal

## Layout
- **Header**: Cancel button (left), "Import Workout" title (center), Import button (right)
- **Body**: ScrollView containing:
  1. AI Workout Prompt section (expandable) with Copy and optional Generate/Open in Claude buttons
  2. Markdown input label + hint
  3. Monospace TextInput for LMWF markdown
  4. Quick Guide help section

## UI Elements

| Element | testID | Type |
|---------|--------|------|
| Screen container | `import-modal` | View |
| Cancel button | `button-cancel` | TouchableOpacity |
| Import button | `button-import` | TouchableOpacity |
| Copy prompt button | `button-copy-prompt` | TouchableOpacity |
| Generate with Claude button | `button-generate` | TouchableOpacity |
| Open in Claude button | `button-open-claude` | TouchableOpacity |
| Markdown input | `input-markdown` | TextInput |

## User Interactions
- **Tap Cancel** → if markdown has content: confirmation alert ("Discard Changes") → navigates back; if empty: navigates back directly
- **Tap Import** → parses markdown via LMWF parser → if warnings: alert with Continue/Cancel → saves plan → success alert → navigates back
- **Tap AI prompt toggle** → expands/collapses prompt preview section
- **Tap Copy** → copies full AI prompt (with equipment, history, custom additions) to clipboard
- **Tap "Generate"** (visible when a usable provider key is set) → calls the first working provider in the user's ordered key list → populates markdown field with result
- **Tap "Open in Claude"** (visible when no API key or showOpenInClaudeButton enabled) → copies prompt to clipboard → opens claude.ai/new in browser
- **Edit markdown field** → updates local state

## Navigation
- Back (via Cancel or after successful import) → previous screen

## Computed Values
- `promptText` — memoized combination of base LMWF prompt + available equipment from default gym + workout history context + custom prompt addition from settings

## Error/Empty States
- **Parse error**: inline red row below the editor (`import-markdown-error`) showing the first parser error; the Import button is disabled while it is shown. When the parser supplies quick fixes (e.g. `MALFORMED_HEADER` for `#push day`), the row has a trailing **Fix** button (`import-markdown-fix-button`) that applies them to the editor text (GH #472). Same `LMWFParseStatusView` as the Edit Plan Markdown sheet — see `spec/screens/workout-detail.md`.
- **Parse warnings**: inline orange captions under the green success row; Import stays enabled. Warnings with quick fixes also get the Fix button.
- **No API key (Generate)**: Alert with options: Cancel, Open in Claude (console), Go to Settings
- **Generation failure**: Alert with error message
- **Copy failure**: Alert "Failed to copy prompt"
- **Open Claude failure**: Alert "Unable to open Claude.ai"
- **Save failure**: Alert with error message
- **Import button disabled**: When `isParsing`, `isGenerating`, or markdown is empty
