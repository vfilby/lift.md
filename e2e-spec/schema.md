# E2E Spec Schema

This document defines the YAML action vocabulary used by the E2E test specification format. Each scenario file describes a test suite with setup, teardown, and individual test cases composed of sequential actions.

## Scenario File Structure

```yaml
name: "Test Suite Name"

setup:
  - action: launchApp
    newInstance: true

teardown:  # optional
  - action: ...

tests:
  - name: "test case name"
    tags: ["smoke"]  # optional, for filtering
    steps:
      - action: tap
        target: "accessibility-id"
      - action: expect
        target: "some-element"
        assertion: "toBeVisible"
```

### Top-Level Fields

| Field      | Required | Description                                      |
|------------|----------|--------------------------------------------------|
| `name`     | yes      | Human-readable name for the test suite           |
| `setup`    | no       | Actions run before each test (beforeEach/beforeAll) |
| `setupOnce`| no       | Actions run once before all tests (beforeAll)    |
| `teardown` | no       | Actions run after each test (afterEach)          |
| `tests`    | yes      | Array of test cases                              |

### Test Case Fields

| Field   | Required | Description                           |
|---------|----------|---------------------------------------|
| `name`  | yes      | Name of the individual test case      |
| `tags`  | no       | Array of tags for filtering/grouping  |
| `steps` | yes      | Array of actions to execute           |

## Action Reference

### tap

Tap on an element.

```yaml
- action: tap
  target: "accessibility-id"
```

| Param    | Required | Description                     |
|----------|----------|---------------------------------|
| `target` | yes      | Accessibility ID of the element |

### longPress

Long press on an element.

```yaml
- action: longPress
  target: "accessibility-id"
```

| Param    | Required | Description                     |
|----------|----------|---------------------------------|
| `target` | yes      | Accessibility ID of the element |

### tapText

Tap on an element matched by visible text.

```yaml
- action: tapText
  text: "OK"
```

| Param  | Required | Description                    |
|--------|----------|--------------------------------|
| `text` | yes      | Visible text to match          |

### tapIndex

Tap on an element at a specific index (when multiple matches exist).

```yaml
- action: tapIndex
  target: "history-session-card"
  index: 0
```

| Param    | Required | Description                     |
|----------|----------|---------------------------------|
| `target` | yes      | Accessibility ID of the element |
| `index`  | yes      | Zero-based index                |

### replaceText

Replace all text in a text input.

```yaml
- action: replaceText
  target: "input-markdown"
  value: "text to enter"
```

| Param    | Required | Description                     |
|----------|----------|---------------------------------|
| `target` | yes      | Accessibility ID of the input   |
| `value`  | yes      | Text to set                     |

Runners must confirm the input actually gained keyboard focus before
synthesizing keystrokes, retrying the focusing tap on a miss — on a loaded CI
host the tap is occasionally dropped, and typing into an unfocused field
aborts the test (XCUITest: "Neither element nor any descendant has keyboard
focus"). Runners must also verify the field holds the intended text after
typing and retry once on mismatch (guards against dropped-keystroke flakes). Secure text fields
(password inputs) cannot be read back as plaintext — their value renders as one
bullet per character — so runners verify by character count instead of
equality. On a final mismatch the typed best-effort text must be left in
place, never a cleared field.

### typeText

Type text into an input (simulates keyboard).

```yaml
- action: typeText
  target: "exercise-picker-search"
  value: "lat pull"
```

| Param    | Required | Description                     |
|----------|----------|---------------------------------|
| `target` | yes      | Accessibility ID of the input   |
| `value`  | yes      | Text to type                    |

### waitFor

Wait for an element to become visible.

```yaml
- action: waitFor
  target: "home-screen"
  timeout: 30000
```

| Param     | Required | Default | Description                   |
|-----------|----------|---------|-------------------------------|
| `target`  | yes      |         | Accessibility ID              |
| `timeout` | no       | 5000    | Max wait time in milliseconds |

### waitForNot

Wait for an element to become not visible.

```yaml
- action: waitForNot
  target: "exercise-picker-modal"
  timeout: 5000
```

| Param     | Required | Default | Description                   |
|-----------|----------|---------|-------------------------------|
| `target`  | yes      |         | Accessibility ID              |
| `timeout` | no       | 5000    | Max wait time in milliseconds |

### waitForText

Wait for an element matched by visible text to become visible.

```yaml
- action: waitForText
  text: "Detox Flow Workout"
  timeout: 10000
```

| Param     | Required | Default | Description                   |
|-----------|----------|---------|-------------------------------|
| `text`    | yes      |         | Visible text to match         |
| `timeout` | no       | 5000    | Max wait time in milliseconds |

### expect

Assert a condition on an element.

```yaml
- action: expect
  target: "home-screen"
  assertion: "toBeVisible"
```

```yaml
- action: expect
  target: "input-field"
  assertion: "toHaveText"
  value: "expected text"
```

| Param       | Required | Description                                  |
|-------------|----------|----------------------------------------------|
| `target`    | yes*     | Accessibility ID (*or use `text`)            |
| `text`      | yes*     | Visible text to match (*or use `target`)     |
| `assertion` | yes      | One of the assertion types below             |
| `value`     | no       | Expected value for `toHaveText`              |

**Assertion types**: `toBeVisible`, `toHaveText`, `toExist`, `notToBeVisible`, `notToExist`

### scroll

Scroll an element in a direction.

```yaml
- action: scroll
  target: "scroll-view"
  direction: "down"
  amount: 300
```

| Param       | Required | Default | Description                    |
|-------------|----------|---------|--------------------------------|
| `target`    | yes      |         | Accessibility ID of scrollable |
| `direction` | yes      |         | `up`, `down`, `left`, `right`  |
| `amount`    | no       | 300     | Pixels to scroll               |

### launchApp

Launch or relaunch the application.

```yaml
- action: launchApp
  newInstance: true
```

| Param         | Required | Default | Description                        |
|---------------|----------|---------|------------------------------------|
| `newInstance`  | no       | false   | Launch as new instance             |
| `permissions`  | no       |         | Object of permission grants        |
| `launchArgs`   | no       |         | Object of launch arguments         |

### openURL

Open a deep link URL.

```yaml
- action: openURL
  url: "liftmark://path/to/resource"
```

| Param | Required | Description        |
|-------|----------|--------------------|
| `url` | yes      | URL to open        |

### dismissAlert

Dismiss a system alert by tapping a button.

```yaml
- action: dismissAlert
  button: "OK"
```

| Param    | Required | Description                    |
|----------|----------|--------------------------------|
| `button` | yes      | Text of the button to tap      |

### delay

Wait for a fixed duration.

```yaml
- action: delay
  ms: 1000
```

| Param | Required | Description                   |
|-------|----------|-------------------------------|
| `ms`  | yes      | Milliseconds to wait          |

### tryCatch

Attempt actions, falling back on failure. Useful for dismissing optional dialogs.

```yaml
- action: tryCatch
  try:
    - action: waitForText
      text: "Finish Anyway"
      timeout: 3000
    - action: tapText
      text: "Finish Anyway"
  catch: []  # empty = swallow error
```

| Param   | Required | Description                              |
|---------|----------|------------------------------------------|
| `try`   | yes      | Actions to attempt                       |
| `catch` | no       | Actions to run on failure (default: [])  |

### runFixture

Import a workout plan from a fixture file. This is a composite action that navigates to home, taps import, enters the fixture content, and confirms.

```yaml
- action: runFixture
  fixture: "simple-workout.md"
  expectedName: "Test Workout"
```

| Param          | Required | Description                                   |
|----------------|----------|-----------------------------------------------|
| `fixture`      | yes      | Filename in e2e-spec/fixtures/                |
| `expectedName` | yes      | Expected workout name after import            |

### execScript

Execute an arbitrary script step (for setup tasks like writing files to the simulator).

```yaml
- action: execScript
  script: "writeSharedFile"
  args:
    filename: "test.md"
    content: "# Test"
```

| Param    | Required | Description                     |
|----------|----------|---------------------------------|
| `script` | yes      | Named script to run             |
| `args`   | no       | Arguments for the script        |
