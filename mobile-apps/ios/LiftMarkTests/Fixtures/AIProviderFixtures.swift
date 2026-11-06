import Foundation

// Recorded payloads are kept byte-for-byte, so some lines run long.
// swiftlint:disable line_length

/// Response bodies for provider contract tests (spec/services/ai-providers.md → Testing).
/// The `*InvalidKey` payloads were captured from the real endpoints with bogus keys
/// (free), and the Ollama payloads from a real local `ollama serve`. Success payloads for
/// hosted providers follow each provider's documented response shape.
enum AIProviderFixtures {

    // MARK: - Anthropic

    static let anthropicMessage = """
    {"id":"msg_01","type":"message","role":"assistant","model":"claude-haiku-4-5-20251001",
     "content":[{"type":"text","text":"# Push Day\\n"},{"type":"text","text":"## Bench Press\\n- 135 x 5"}],
     "stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":12}}
    """

    static let anthropicModels = """
    {"data":[
      {"type":"model","id":"claude-sonnet-4-5-20250929","display_name":"Claude Sonnet 4.5"},
      {"type":"model","id":"claude-haiku-4-5-20251001","display_name":"Claude Haiku 4.5"}
    ],"has_more":false,"first_id":"claude-sonnet-4-5-20250929","last_id":"claude-haiku-4-5-20251001"}
    """

    static let anthropicInvalidKey = """
    {"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"},"request_id":"req_011CgJ53RGSQuZ2nMqqz1X1r"}
    """

    static let anthropicOverloaded = """
    {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
    """

    // MARK: - OpenAI

    static let openAIChatCompletion = """
    {"id":"chatcmpl-1","object":"chat.completion","created":1761170000,"model":"gpt-5-mini",
     "choices":[{"index":0,"message":{"role":"assistant","content":"# Pull Day\\n## Row\\n- 95 x 8"},
     "finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":12,"total_tokens":22}}
    """

    static let openAIModels = """
    {"object":"list","data":[
      {"id":"gpt-5-mini","object":"model","owned_by":"system"},
      {"id":"text-embedding-3-small","object":"model","owned_by":"system"},
      {"id":"gpt-4o-realtime-preview","object":"model","owned_by":"system"},
      {"id":"o4-mini","object":"model","owned_by":"system"},
      {"id":"dall-e-3","object":"model","owned_by":"system"},
      {"id":"gpt-4o-mini-tts","object":"model","owned_by":"system"},
      {"id":"chatgpt-4o-latest","object":"model","owned_by":"system"},
      {"id":"gpt-4.1","object":"model","owned_by":"system"},
      {"id":"whisper-1","object":"model","owned_by":"system"}
    ]}
    """

    static let openAIInvalidKey = """
    {
      "error": {
        "message": "Incorrect API key provided: sk-proj-*********************ogus. You can find your API key at https://platform.openai.com/account/api-keys.",
        "type": "invalid_request_error",
        "param": null,
        "code": "invalid_api_key"
      }
    }
    """

    static let openAIModelNotFound = """
    {"error":{"message":"The model `gpt-nope` does not exist or you do not have access to it.",
     "type":"invalid_request_error","param":null,"code":"model_not_found"}}
    """

    static let openAIInsufficientQuota = """
    {"error":{"message":"You exceeded your current quota, please check your plan and billing details.",
     "type":"insufficient_quota","param":null,"code":"insufficient_quota"}}
    """

    static let openAIUnsupportedRegion = """
    {"error":{"code":"unsupported_country_region_territory",
     "message":"Country, region, or territory not supported","param":null,"type":"request_forbidden"}}
    """

    // MARK: - Gemini

    static let geminiGenerateContent = """
    {"candidates":[{"content":{"role":"model","parts":[
      {"text":"Planning a leg day...","thought":true},
      {"text":"# Leg Day\\n"},
      {"text":"## Squat\\n- 225 x 5"}
    ]},"finishReason":"STOP","index":0}],
     "usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":12,"totalTokenCount":22},
     "modelVersion":"gemini-2.5-flash"}
    """

    static let geminiModels = """
    {"models":[
      {"name":"models/gemini-2.5-flash","displayName":"Gemini 2.5 Flash",
       "supportedGenerationMethods":["generateContent","countTokens","createCachedContent"]},
      {"name":"models/text-embedding-004","displayName":"Text Embedding 004",
       "supportedGenerationMethods":["embedContent"]},
      {"name":"models/gemini-2.5-pro","displayName":"Gemini 2.5 Pro",
       "supportedGenerationMethods":["generateContent","countTokens"]}
    ]}
    """

    static let geminiInvalidKey = """
    {
      "error": {
        "code": 400,
        "message": "API key not valid. Please pass a valid API key.",
        "status": "INVALID_ARGUMENT",
        "details": [
          {
            "@type": "type.googleapis.com/google.rpc.ErrorInfo",
            "reason": "API_KEY_INVALID",
            "domain": "googleapis.com",
            "metadata": {
              "service": "generativelanguage.googleapis.com"
            }
          },
          {
            "@type": "type.googleapis.com/google.rpc.LocalizedMessage",
            "locale": "en-US",
            "message": "API key not valid. Please pass a valid API key."
          }
        ]
      }
    }
    """

    static let geminiBadRequest = """
    {"error":{"code":400,"message":"Invalid JSON payload received.","status":"INVALID_ARGUMENT"}}
    """

    static let geminiNoText = """
    {"candidates":[{"content":{"role":"model","parts":[{"text":"thinking only","thought":true}]},
     "finishReason":"MAX_TOKENS","index":0}]}
    """

    // MARK: - Ollama

    static let ollamaChat = """
    {"model":"qwen2.5:0.5b","created_at":"2026-10-22T22:33:10.010012Z","message":{"role":"assistant","content":"# Push Day"},"done":true,"done_reason":"stop","total_duration":1487798000,"load_duration":1031207042,"prompt_eval_count":36,"prompt_eval_cached_count":0,"prompt_eval_duration":252796000,"eval_count":4,"eval_duration":199921000}
    """

    static let ollamaTags = """
    {"models":[{"name":"qwen2.5:0.5b","model":"qwen2.5:0.5b","modified_at":"2026-10-22T22:32:39.28882624Z","size":397821319,"digest":"a8b0c51577010a279d933d14c2a8ab4b268079d44c5c8830c0a93900f1827c67","details":{"parent_model":"","format":"gguf","family":"qwen2","families":["qwen2"],"parameter_size":"494.03M","quantization_level":"Q4_K_M"}},{"name":"llama3.2:latest","model":"llama3.2:latest","size":2019393189}]}
    """

    static let ollamaModelNotFound = """
    {"error":"model 'nope' not found"}
    """

    static func data(_ json: String) -> Data { Data(json.utf8) }
}
// swiftlint:enable line_length
