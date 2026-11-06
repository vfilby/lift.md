# Secure Storage Service Specification

## Purpose

Securely store and retrieve secrets using the platform's secure storage mechanism (iOS Keychain). API keys are never stored in the database or in plaintext on disk.

The BYOK provider key list (Anthropic, OpenAI, Gemini, Ollama) is stored as one Keychain item through the generic accessors below. See `spec/services/ai-providers.md`. The Anthropic-specific API in this file is **legacy**: it is kept only so the one-time migration into the provider list can read and delete the old item.

## Public API

Key format validation lives with the provider definitions (`AIProvider.isValidKeyFormat`, `spec/services/ai-providers.md`), not in secure storage.

### `getLegacyAnthropicApiKey(): string | null`

Retrieves the legacy Anthropic API key (account `anthropic_api_key`). Used only by the provider-list migration.

Returns the key string if present, or `null` if no key is stored. Swallows all errors and returns `null` on failure (defensive — never crashes the app for a missing key).

### `removeLegacyAnthropicApiKey(): void`

Deletes the legacy Anthropic key from secure storage. Throws on failure; a missing item is not an error.

### Generic accessors: `store(key, value)`, `retrieve(key)`, `delete(key)`

Store, read, or delete an arbitrary UTF-8 string under a Keychain account. The provider key list uses account `ai_provider_keys`.

## Storage Details

| Property | Value |
|----------|-------|
| Storage key (provider list) | `ai_provider_keys` |
| Storage key (legacy, migrated away) | `anthropic_api_key` |
| Platform mechanism | iOS Keychain (via platform secure storage API) |
| Accessibility | When unlocked, this device only (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) |

## Dependencies

- Platform-specific secure storage API (e.g., `expo-secure-store` on React Native, `Keychain` on native iOS).

## Error Handling

- `store` throws on encoding or storage failure.
- `retrieve` / `getLegacyAnthropicApiKey` never throw; they return `null` on any error.
- `delete` / `removeLegacyAnthropicApiKey` throw on failure (a missing item is not a failure).
