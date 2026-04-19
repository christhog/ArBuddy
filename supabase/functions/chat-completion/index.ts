/**
 * Chat Completion Edge Function
 * Proxies requests to Claude Haiku API with SSE streaming support
 */

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

interface ChatMessage {
  role: "user" | "assistant";
  content: string;
}

interface ChatCompletionRequest {
  messages: ChatMessage[];
  systemPrompt?: string;
  maxTokens?: number;
}

Deno.serve(async (req) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { messages, systemPrompt, maxTokens } = await req.json() as ChatCompletionRequest;

    if (!messages || !Array.isArray(messages) || messages.length === 0) {
      return new Response(
        JSON.stringify({ error: "messages array is required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const anthropicApiKey = Deno.env.get("ANTHROPIC_API_KEY");
    if (!anthropicApiKey) {
      console.error("ANTHROPIC_API_KEY not configured");
      return new Response(
        JSON.stringify({ error: "API key not configured" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`[chat-completion] Processing ${messages.length} messages`);

    // Build the request to Anthropic API
    const anthropicRequest = {
      model: "claude-3-haiku-20240307",
      max_tokens: maxTokens || 1024,
      system: systemPrompt || "Du bist ein freundlicher und hilfreicher AR-Buddy Assistent. Antworte auf Deutsch.",
      messages: messages.map(m => ({
        role: m.role,
        content: m.content
      })),
      stream: true,
    };

    // Call Anthropic API with streaming
    const response = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": anthropicApiKey,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify(anthropicRequest),
    });

    if (!response.ok) {
      const errorText = await response.text();
      console.error(`[chat-completion] Anthropic API error: ${response.status}`, errorText);
      return new Response(
        JSON.stringify({ error: `Anthropic API error: ${response.status}` }),
        { status: response.status, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Stream SSE response through to the client
    // The Anthropic response is already in SSE format
    return new Response(response.body, {
      headers: {
        ...corsHeaders,
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        "Connection": "keep-alive",
      },
    });

  } catch (error) {
    console.error("[chat-completion] Error:", error);
    return new Response(
      JSON.stringify({ error: error.message || "Failed to process chat completion" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
