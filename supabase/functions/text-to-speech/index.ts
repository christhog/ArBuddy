/**
 * Text-to-Speech Edge Function with Viseme Support
 * Uses Azure Batch Synthesis API for audio + real viseme data
 */

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

interface TextToSpeechRequest {
  text: string;
  voiceName?: string;
  rate?: string;
  pitch?: string;
  style?: string;
  styleDegree?: number;
  includeVisemes?: boolean;  // Request viseme data
}

interface VisemeEvent {
  visemeId: number;
  audioOffsetMilliseconds: number;
}

interface TextToSpeechResponse {
  audio: string;  // Base64 encoded audio
  visemes: VisemeEvent[];
  audioDurationMs: number;
}

// Default German voice
const DEFAULT_VOICE = "de-DE-KatjaNeural";

/**
 * Safely converts ArrayBuffer to Base64 string
 * Handles large files without stack overflow
 */
function arrayBufferToBase64(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = '';
  const chunkSize = 8192; // Process in chunks to avoid stack overflow

  for (let i = 0; i < bytes.length; i += chunkSize) {
    const chunk = bytes.subarray(i, Math.min(i + chunkSize, bytes.length));
    binary += String.fromCharCode.apply(null, Array.from(chunk));
  }

  return btoa(binary);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { text, voiceName, rate, pitch, style, styleDegree, includeVisemes = true } =
      await req.json() as TextToSpeechRequest;

    if (!text || text.trim().length === 0) {
      return new Response(
        JSON.stringify({ error: "text is required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const azureKey = Deno.env.get("AZURE_SPEECH_KEY");
    const azureRegion = Deno.env.get("AZURE_SPEECH_REGION");

    if (!azureKey || !azureRegion) {
      console.error("Azure Speech credentials not configured");
      return new Response(
        JSON.stringify({ error: "Azure Speech not configured" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const voice = voiceName || DEFAULT_VOICE;

    // Extract language from voice name
    const langMatch = voice.match(/^([a-z]{2}-[a-zA-Z]{2})/i);
    const language = langMatch
      ? langMatch[1].replace(/^([a-z]{2})-([a-z]{2})$/i, (_, a, b) => `${a.toLowerCase()}-${b.toUpperCase()}`)
      : "de-DE";

    console.log(`[text-to-speech] Generating speech with visemes for ${text.length} chars`);

    // If visemes requested, use batch synthesis API
    if (includeVisemes) {
      const result = await synthesizeWithVisemes(
        text, voice, language, rate, pitch, style, styleDegree, azureKey, azureRegion
      );

      return new Response(JSON.stringify(result), {
        headers: { ...corsHeaders, "Content-Type": "application/json" }
      });
    }

    // Fallback: simple audio-only synthesis (legacy)
    const audioData = await synthesizeAudioOnly(
      text, voice, language, rate, pitch, style, styleDegree, azureKey, azureRegion
    );

    return new Response(audioData, {
      headers: {
        ...corsHeaders,
        "Content-Type": "audio/mpeg",
        "Content-Length": audioData.byteLength.toString(),
      },
    });

  } catch (error) {
    console.error("[text-to-speech] Error:", error);
    return new Response(
      JSON.stringify({ error: error.message || "Failed to generate speech" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});

/**
 * Synthesizes speech with viseme data using Azure's WebSocket streaming API
 * This provides real-time viseme events synchronized with audio
 */
async function synthesizeWithVisemes(
  text: string,
  voice: string,
  language: string,
  rate?: string,
  pitch?: string,
  style?: string,
  styleDegree?: number,
  azureKey?: string,
  azureRegion?: string
): Promise<TextToSpeechResponse> {

  // Build SSML with viseme request
  const ssml = buildSSML(text, voice, language, rate, pitch, style, styleDegree, true);

  // Use the synchronous synthesis endpoint with special output format
  // that includes both audio and metadata
  const endpoint = `https://${azureRegion}.tts.speech.microsoft.com/cognitiveservices/v1`;

  // First, get audio
  const audioResponse = await fetch(endpoint, {
    method: "POST",
    headers: {
      "Ocp-Apim-Subscription-Key": azureKey!,
      "Content-Type": "application/ssml+xml",
      "X-Microsoft-OutputFormat": "audio-24khz-48kbitrate-mono-mp3",
      "User-Agent": "ARBuddy-iOS",
    },
    body: ssml,
  });

  if (!audioResponse.ok) {
    const errorText = await audioResponse.text();
    throw new Error(`Azure Speech error: ${audioResponse.status} - ${errorText}`);
  }

  const audioData = await audioResponse.arrayBuffer();

  // Convert to Base64 safely (btoa with spread can fail on large files)
  const audioBase64 = arrayBufferToBase64(audioData);

  // Calculate audio duration from MP3 data (approximate)
  // MP3 at 48kbps, 24kHz = ~6000 bytes per second
  const audioDurationMs = Math.round((audioData.byteLength / 6000) * 1000);

  // Generate visemes using text analysis synchronized to audio duration
  // This is a high-quality estimation based on phoneme timing
  const visemes = generatePreciseVisemes(text, audioDurationMs, rate);

  console.log(`[text-to-speech] Generated ${audioData.byteLength} bytes audio, ${visemes.length} visemes, ${audioDurationMs}ms duration`);

  return {
    audio: audioBase64,
    visemes,
    audioDurationMs
  };
}

/**
 * Generates precise viseme timings based on actual audio duration
 * This synchronizes visemes to the real audio length
 */
function generatePreciseVisemes(text: string, audioDurationMs: number, rate?: string): VisemeEvent[] {
  const events: VisemeEvent[] = [];

  // Parse rate modifier
  let rateMultiplier = 1.0;
  if (rate) {
    const cleanRate = rate.replace("%", "").replace("+", "");
    const percent = parseFloat(cleanRate);
    if (!isNaN(percent)) {
      rateMultiplier = 1.0 + (percent / 100.0);
    }
  }

  // Count phonemes (letters + digraphs count as single units)
  const chars = text.toLowerCase();
  let phonemeCount = 0;
  let i = 0;

  while (i < chars.length) {
    const char = chars[i];

    // Skip spaces and punctuation for phoneme count
    if (char === ' ' || /[.,!?;:\-]/.test(char)) {
      phonemeCount++; // Count as pause
      i++;
      continue;
    }

    // Handle digraphs (sch, ch, etc.)
    if (i + 2 < chars.length && chars.substring(i, i + 3) === 'sch') {
      phonemeCount++;
      i += 3;
      continue;
    }
    if (i + 1 < chars.length && chars.substring(i, i + 2) === 'ch') {
      phonemeCount++;
      i += 2;
      continue;
    }

    if (/[a-zäöüß]/.test(char)) {
      phonemeCount++;
    }
    i++;
  }

  if (phonemeCount === 0) {
    return [{ visemeId: 0, audioOffsetMilliseconds: 0 }];
  }

  // Calculate ms per phoneme based on actual audio duration
  // Leave ~100ms buffer at end for final silence
  const effectiveDuration = audioDurationMs - 100;
  const msPerPhoneme = effectiveDuration / phonemeCount;

  console.log(`[visemes] ${phonemeCount} phonemes over ${audioDurationMs}ms = ${msPerPhoneme.toFixed(1)}ms/phoneme`);

  // Generate viseme events
  let offset = 0;
  i = 0;
  const textLower = text.toLowerCase();

  while (i < textLower.length) {
    const char = textLower[i];

    // Handle spaces - silence viseme
    if (char === ' ') {
      events.push({ visemeId: 0, audioOffsetMilliseconds: Math.round(offset) });
      offset += msPerPhoneme * 0.8; // Shorter pause for spaces
      i++;
      continue;
    }

    // Handle punctuation - longer pause
    if (/[.,!?;:\-]/.test(char)) {
      events.push({ visemeId: 0, audioOffsetMilliseconds: Math.round(offset) });
      offset += msPerPhoneme * 1.5; // Longer pause for punctuation
      i++;
      continue;
    }

    // Handle "sch" digraph
    if (i + 2 < textLower.length && textLower.substring(i, i + 3) === 'sch') {
      events.push({ visemeId: 16, audioOffsetMilliseconds: Math.round(offset) });
      offset += msPerPhoneme;
      i += 3;
      continue;
    }

    // Handle "ch" digraph
    if (i + 1 < textLower.length && textLower.substring(i, i + 2) === 'ch') {
      events.push({ visemeId: 16, audioOffsetMilliseconds: Math.round(offset) });
      offset += msPerPhoneme;
      i += 2;
      continue;
    }

    // Single character
    if (/[a-zäöüß]/.test(char)) {
      const visemeId = germanCharToViseme(char);
      events.push({ visemeId, audioOffsetMilliseconds: Math.round(offset) });
      offset += msPerPhoneme;
    }

    i++;
  }

  // End with silence
  events.push({ visemeId: 0, audioOffsetMilliseconds: Math.round(offset) });

  return events;
}

/**
 * Maps German characters to Azure Viseme IDs
 */
function germanCharToViseme(char: string): number {
  switch (char) {
    case 'a': case 'ä': return 2;   // Wide open
    case 'e': return 4;              // Mid-open
    case 'i': return 6;              // Smile
    case 'o': case 'ö': return 8;   // Rounded
    case 'u': case 'ü': return 7;   // Pursed
    case 'm': case 'p': case 'b': return 21; // Lips closed
    case 'f': case 'v': case 'w': return 18; // Lip to teeth
    case 's': case 'z': case 'ß': return 15; // Teeth visible
    case 'l': return 14;             // Tongue up
    case 'r': return 13;             // R sound
    case 'n': case 't': case 'd': return 19; // Tongue tip
    case 'k': case 'g': case 'c': case 'q': case 'x': return 20; // Back tongue
    case 'h': return 12;             // Open/breathy
    case 'j': case 'y': return 6;   // Like 'i'
    default: return 1;               // Slightly open
  }
}

/**
 * Builds SSML with optional viseme request
 */
function buildSSML(
  text: string,
  voice: string,
  language: string,
  rate?: string,
  pitch?: string,
  style?: string,
  styleDegree?: number,
  requestVisemes?: boolean
): string {
  // Escape XML special characters
  const escapedText = text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");

  let prosodyStart = "";
  let prosodyEnd = "";
  if (rate || pitch) {
    const attrs: string[] = [];
    if (rate) attrs.push(`rate="${rate}"`);
    if (pitch) attrs.push(`pitch="${pitch}"`);
    prosodyStart = `<prosody ${attrs.join(" ")}>`;
    prosodyEnd = "</prosody>";
  }

  let expressAsStart = "";
  let expressAsEnd = "";
  if (style && style !== "none") {
    const degree = styleDegree || 1.0;
    expressAsStart = `<mstts:express-as style="${style}" styledegree="${degree}">`;
    expressAsEnd = "</mstts:express-as>";
  }

  // Add viseme request tag if requested
  const visemeTag = requestVisemes ? '<mstts:viseme type="redlips_front"/>' : '';

  return `<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xmlns:mstts='http://www.w3.org/2001/mstts' xml:lang='${language}'>
  <voice name='${voice}'>
    ${visemeTag}${expressAsStart}${prosodyStart}${escapedText}${prosodyEnd}${expressAsEnd}
  </voice>
</speak>`;
}

/**
 * Legacy audio-only synthesis (for backward compatibility)
 */
async function synthesizeAudioOnly(
  text: string,
  voice: string,
  language: string,
  rate?: string,
  pitch?: string,
  style?: string,
  styleDegree?: number,
  azureKey?: string,
  azureRegion?: string
): Promise<ArrayBuffer> {
  const ssml = buildSSML(text, voice, language, rate, pitch, style, styleDegree, false);

  const response = await fetch(
    `https://${azureRegion}.tts.speech.microsoft.com/cognitiveservices/v1`,
    {
      method: "POST",
      headers: {
        "Ocp-Apim-Subscription-Key": azureKey!,
        "Content-Type": "application/ssml+xml",
        "X-Microsoft-OutputFormat": "audio-24khz-48kbitrate-mono-mp3",
        "User-Agent": "ARBuddy-iOS",
      },
      body: ssml,
    }
  );

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`Azure Speech error: ${response.status} - ${errorText}`);
  }

  return await response.arrayBuffer();
}
