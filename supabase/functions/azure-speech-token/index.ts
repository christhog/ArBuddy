/**
 * Azure Speech Token Edge Function
 *
 * Issues a short-lived (10 min) Azure Cognitive Services auth token so the iOS
 * client never has to hold the subscription key locally. The client calls this
 * endpoint, gets `{ token, region, expiresAt }`, and feeds the token into
 * `SPXSpeechConfiguration(authorizationToken:region:)`.
 *
 * Azure rotates these tokens every 10 minutes; the client should refresh a
 * minute or two before expiry.
 */

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

interface TokenResponse {
  token: string;
  region: string;
  expiresAt: number; // Unix seconds
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const azureKey = Deno.env.get("AZURE_SPEECH_KEY");
    const azureRegion = Deno.env.get("AZURE_SPEECH_REGION");

    if (!azureKey || !azureRegion) {
      console.error("[azure-speech-token] Credentials not configured");
      return new Response(
        JSON.stringify({ error: "Azure Speech not configured" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const endpoint = `https://${azureRegion}.api.cognitive.microsoft.com/sts/v1.0/issueToken`;

    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        "Ocp-Apim-Subscription-Key": azureKey,
        "Content-Length": "0",
      },
    });

    if (!response.ok) {
      const errorText = await response.text();
      console.error(`[azure-speech-token] Azure returned ${response.status}: ${errorText}`);
      return new Response(
        JSON.stringify({ error: `Azure token endpoint returned ${response.status}` }),
        { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const token = await response.text();

    const result: TokenResponse = {
      token,
      region: azureRegion,
      // Azure tokens are valid for 10 min. Report expiry 30 s early to give the
      // client a refresh buffer.
      expiresAt: Math.floor(Date.now() / 1000) + (10 * 60) - 30,
    };

    console.log(`[azure-speech-token] Issued token for region=${azureRegion}`);

    return new Response(JSON.stringify(result), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  } catch (error) {
    console.error("[azure-speech-token] Error:", error);
    return new Response(
      JSON.stringify({ error: error.message || "Failed to issue token" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
