# AI Providers (BYOK) Specification

## Purpose

Let the user bring their own key (BYOK) for more than one LLM provider and use it for in-app workout generation. Supported providers:

| Provider | `AIProvider` raw value | Needs API key | Default model |
|---|---|---|---|
| Anthropic (Claude) | `anthropic` | Yes | `claude-haiku-4-5-20251001` |
| OpenAI (ChatGPT) | `openai` | Yes | `gpt-5-mini` |
| Google Gemini | `gemini` | Yes | `gemini-2.5-flash` |
| Ollama (self-hosted) | `ollama` | No (optional bearer token) | `llama3.2` |

The user keeps an **ordered list** of provider keys. Generation tries keys top to bottom and uses the first one that succeeds, so the list order is the user's preference and fallback order.

## Data Model

### `AIProviderKey`

| Field | Type | Notes |
|---|---|---|
| `id` | String (UUID) | Stable identity used for reordering/deleting |
| `provider` | `AIProvider` | |
| `apiKey` | String | Trimmed. Empty for Ollama when no token is configured |
| `model` | String | Model id sent to the provider. Defaults to the provider default when left blank |
| `baseURL` | String? | Ollama only. Defaults to `http://localhost:11434` |
| `status` | `AIKeyStatus` | `verified`, `unverified`, `invalid` |

### `AIKeyStatus`

- `verified` — the provider accepted the credential (verification call or a successful generation).
- `unverified` — format is valid, but the free verification call could not complete (offline, Ollama server not reachable, provider 5xx). Verification is deferred to first use.
- `invalid` — the provider rejected the credential (401, or Gemini `API_KEY_INVALID`). Invalid keys are skipped during generation until edited or re-verified. A 403 does **not** mark a key invalid: region blocks and per-model permission errors return 403 for keys that are otherwise fine.

### Storage

- The whole ordered list is JSON-encoded and stored as **one** Keychain item (account `ai_provider_keys`, service `com.liftmark.app`, accessibility `WhenUnlockedThisDeviceOnly`). It contains secrets, so it is never written to SQLite, UserDefaults, or CloudKit.
- Device-local; never synced. Each device keeps its own list.
- `--reset-data` (UI-test isolation) deletes the item.

### Legacy migration

Before multi-provider support, a single Anthropic key lived in the Keychain account `anthropic_api_key`, and `user_settings.anthropic_api_key_status` tracked its state. On first load, when `ai_provider_keys` is absent and the legacy item exists, the store:

1. Creates one `anthropic` entry with the legacy key, the default model, and status `verified` if `anthropic_api_key_status == verified`, otherwise `unverified`.
2. Persists the list, then deletes the legacy Keychain item. If the list can't be persisted, the legacy item stays and migration retries on the next load. Whenever the list exists at load time and a legacy item is still present (from an interrupted migration), the legacy item is deleted best-effort.

If the stored list can't be decoded, it loads as empty and the error is logged and recorded in `AIKeyStore.lastError`.

`anthropic_api_key_status` is now a legacy column. The app no longer reads it, except during this one-time migration, and no longer writes it. It stays in the schema so no migration or CloudKit change is needed.

## Key Validation (no token spend)

Validating a key must not spend tokens. It runs in two stages:

### 1. Format check (offline, blocks saving)

| Provider | Rule |
|---|---|
| Anthropic | `^sk-ant-[a-zA-Z0-9_-]{95,}$` |
| OpenAI | `^sk-[A-Za-z0-9_-]{20,}$` (covers `sk-proj-…`, `sk-svcacct-…`, legacy `sk-…`) |
| Gemini | `^AIza[0-9A-Za-z_-]{35}$` (Google API keys are 39 chars) |
| Ollama | No key required. Base URL must parse as an `http`/`https` URL with a host |

Input is trimmed before checking.

### 2. Free verification call (list models)

Every provider has a free list-models endpoint. Calling it authenticates the key without generating tokens, and it returns the model ids used to fill the model picker.

| Provider | Request | Auth | Model ids |
|---|---|---|---|
| Anthropic | `GET https://api.anthropic.com/v1/models?limit=100` | `x-api-key`, `anthropic-version: 2023-06-01` | `data[].id` |
| OpenAI | `GET https://api.openai.com/v1/models` | `Authorization: Bearer <key>` | `data[].id`, filtered to chat models (prefix `gpt-`, `chatgpt-`, `o1`, `o3`, `o4`; excluding ids containing `audio`, `realtime`, `transcribe`, `tts`, `image`, `search`) |
| Gemini | `GET https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000` | `x-goog-api-key` | `models[].name` minus the `models/` prefix, only where `supportedGenerationMethods` contains `generateContent` |
| Ollama | `GET {baseURL}/api/tags` | `Authorization: Bearer <key>` only when a key is set | `models[].name` |

Model ids are returned sorted ascending.

Outcome mapping:

| Response | Status | Saved? |
|---|---|---|
| 200 | `verified` | Yes |
| 401, or Gemini 400 whose body contains `API_KEY_INVALID` | `invalid` | No. The error is shown in the sheet |
| Transport error, timeout, 403, 429, 5xx, other | `unverified` | Yes, with a "will verify on first use" note |

The verification request times out after 15 s.

## Generation

### Requests

All providers get the same single user-turn prompt built by `WorkoutGenerationService`.

| Provider | Request | Body | Text extraction |
|---|---|---|---|
| Anthropic | `POST https://api.anthropic.com/v1/messages` | `{model, max_tokens: 4096, messages:[{role:"user", content}]}` | Concatenate `content[].text` where `type == "text"` |
| OpenAI | `POST https://api.openai.com/v1/chat/completions` | `{model, max_completion_tokens: 16000, messages:[{role:"user", content}]}` | `choices[0].message.content` |
| Gemini | `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent` | `{contents:[{role:"user", parts:[{text}]}], generationConfig:{maxOutputTokens: 16000}}` | Concatenate `candidates[0].content.parts[].text`, skipping parts with `thought == true` |
| Ollama | `POST {baseURL}/api/chat` | `{model, stream:false, messages:[{role:"user", content}]}` | `message.content` |

OpenAI and Gemini default models are reasoning models, and reasoning tokens count against the output limit, so they get a higher token ceiling than Anthropic. The generation request times out after 120 s. A blank model falls back to the provider default.

### Error mapping

| Condition | `type` | Message |
|---|---|---|
| Missing key (key-requiring provider) | `missing_api_key` | "API key is required. Add your {Provider} key in Settings." |
| 401 / Gemini `API_KEY_INVALID` | `invalid_api_key` | "Invalid {Provider} API key. Check it in Settings." |
| 403 | `permission_denied` | Provider error message if present, else "{Provider} denied access for this key." |
| 404 | `model_not_found` | Provider error message if present, else "Model "{model}" was not found on {Provider}." |
| 429 | `rate_limit` | Provider error message if present (OpenAI's `insufficient_quota` also uses 429), else "{Provider} rate limit exceeded. Please try again in a moment." |
| 400 | `bad_request` | Provider error message if present, else "Invalid request. Please try again." |
| other non-200 | `server_error` | "{Provider} is currently unavailable. Please try again later." |
| 200 but no text | `empty_response` | "No workout generated. Please try again." |
| Transport error | `network_error` | "Couldn't reach {Provider}. Check your connection." (Ollama: "Couldn't reach Ollama at {baseURL}. Is the server running and reachable from this device?") |

Error messages are read from `error.message` (Anthropic/OpenAI/Gemini) or from a top-level `error` string (Ollama).

### Ordered fallback

`AIProviderService.generateWorkout(prompt:keys:)`:

1. Considers keys in list order and skips `invalid` ones.
2. Calls each key's provider. The first success is returned along with the key id that produced it.
3. If a key fails, it tries the next key. A key that fails with `invalid_api_key` is reported back so the store can mark it `invalid`. A key that succeeds while `unverified` is marked `verified`.
4. If every usable key fails and there was only one attempt, that attempt's error is returned unchanged. With several attempts, the error message lists each one as `"{Provider}: {message}"` on its own line. The `type` is `all_providers_failed`.
5. If there are no usable keys, it returns `missing_api_key`.

### Gating

The Generate button in "Build with AI" is shown when the list has at least one non-`invalid` key (`AIKeyStore.hasUsableKey`).

## Transport security (Ollama)

Ollama usually runs over plain `http` on the local network. The app's Info.plist sets `NSAppTransportSecurity.NSAllowsLocalNetworking = true`, which allows plain HTTP to local addresses (`.local`, private IPs, unqualified hosts) without relaxing ATS for the public internet. It also sets `NSLocalNetworkUsageDescription`. The Ollama hint text tells users to set `OLLAMA_HOST=0.0.0.0` on the server and enter the machine's LAN address.

## Testing

### iOS unit (`LiftMarkTests`)

These need no network or credentials and run in the PR gate.

- `AIProviderTests`: format rules per provider (valid, wrong prefix, too short, whitespace trimming, internal whitespace); Ollama base URL validation; display metadata (every provider has a name, default model, and placeholder); `AIProviderKey` helpers (`effectiveModel`, `effectiveBaseURL` trailing-slash normalisation, `maskedHint`, `formatError`, and Ollama-only `modelAvailabilityError`, including the `:latest` match).
- `AIProviderRequestTests`: for each provider, the generate and verify request builders produce the right URL, method, auth headers, and JSON body. Gemini model ids are percent-encoded in the path, Ollama's trailing `/` is normalised, Ollama sends no `Authorization` header without a key, and a blank model uses the default.
- `AIProviderResponseTests` (contract tests): recorded response bodies (`LiftMarkTests/Fixtures/AIProviderFixtures.swift`; error payloads were captured from the real endpoints with bogus keys, and Ollama payloads from a real local server), shaped like each provider's documented success, model-list, and error payloads, are parsed into text, model ids, and error types. Covers Anthropic multi-block text, Gemini thought-part skipping, OpenAI chat-model filtering, Gemini `generateContent` filtering, and Gemini `API_KEY_INVALID` → invalid.
- `AIProviderServiceTests`: through a stub `URLProtocol` session, covers verification outcome mapping (200 → verified + models, 401 → invalid, 403 / 5xx / transport error → unverified), 403 during generation falls back without marking the key invalid, ordered fallback (first fails → second used), skipping invalid keys, invalid-key reporting, a single error passed through unchanged, multiple errors aggregated, and no usable keys → `missing_api_key`.
- `AIKeyStoreTests`: add/update/remove/move with persistence round-trip through an injected in-memory backing store; a failed persist leaves state unchanged; a corrupt list loads empty and records an error; legacy Anthropic migration (status mapping, legacy item deleted only after persisting the new list, no import when the list already exists, leftover legacy item cleaned up); `hasUsableKey`; applying generation outcomes (marks invalid / verified).
- `SecureStorageTests`: real-Keychain round-trips for the generic accessors, the legacy Anthropic item, and `KeychainAIKeyStorage`.

### Live provider tests (opt-in, local only)

`AIProviderLiveTests` call real endpoints and are skipped unless the matching variable is in the test environment. CI never sets them. Pass them with the `TEST_RUNNER_` prefix:

| Variable | Exercises | Cost |
|---|---|---|
| `LIFTMARK_LIVE_ANTHROPIC_KEY` | verify (list models) | Free |
| `LIFTMARK_LIVE_OPENAI_KEY` | verify (list models) | Free |
| `LIFTMARK_LIVE_GEMINI_KEY` | verify (list models) | Free |
| `LIFTMARK_LIVE_OLLAMA_URL` (+ optional `LIFTMARK_LIVE_OLLAMA_MODEL`) | verify + full generation | Free (local model) |

Every hosted provider also gets a negative test with a well-formed but bogus key, which must come back `invalid`. These run whenever `LIFTMARK_LIVE_AI_NEGATIVE=1` is set, need no account, and are free. They catch drift in the auth error shape.

Ollama is the free end-to-end integration environment. Example:

```bash
brew install ollama && ollama serve &   # then: ollama pull qwen2.5:0.5b
TEST_RUNNER_LIFTMARK_LIVE_OLLAMA_URL=http://localhost:11434 \
TEST_RUNNER_LIFTMARK_LIVE_OLLAMA_MODEL=qwen2.5:0.5b \
TEST_RUNNER_LIFTMARK_LIVE_AI_NEGATIVE=1 \
xcodebuild test -scheme LiftMark -project LiftMark.xcodeproj -testPlan Full \
  -only-testing:LiftMarkTests/AIProviderLiveTests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest'
```
