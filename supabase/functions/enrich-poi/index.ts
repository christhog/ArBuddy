import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Anthropic from "https://esm.sh/@anthropic-ai/sdk@0.24.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

interface QuizQuestion {
  question: string;
  answers: string[];
  correctAnswerIndex: number;
}

interface MysteryEvent {
  story: string;
  clues: string[];
  solution: string;
}

interface TreasureEvent {
  riddle: string;
  nextPoiHint: string;
}

interface TimetravelEvent {
  era: string;
  historicalFacts: string[];
  whatIf: string;
}

type ContentType = "quiz" | "game-event";
type EventType = "mystery" | "treasure" | "timetravel";

Deno.serve(async (req) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { poiId, contentType, eventType } = await req.json() as {
      poiId: string;
      contentType: ContentType;
      eventType?: EventType;
    };

    if (!poiId) {
      return new Response(
        JSON.stringify({ error: "poiId is required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!contentType || !["quiz", "game-event"].includes(contentType)) {
      return new Response(
        JSON.stringify({ error: "contentType must be 'quiz' or 'game-event'" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (contentType === "game-event" && (!eventType || !["mystery", "treasure", "timetravel"].includes(eventType))) {
      return new Response(
        JSON.stringify({ error: "eventType must be 'mystery', 'treasure', or 'timetravel' for game-event" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Initialize Supabase client
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Get POI from database
    const { data: poi, error: poiError } = await supabase
      .from('pois')
      .select('*')
      .eq('id', poiId)
      .single();

    if (poiError || !poi) {
      return new Response(
        JSON.stringify({ error: "POI not found" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Check if content already exists
    if (contentType === "quiz" && poi.quiz_questions) {
      console.log(`Quiz already exists for POI: ${poi.name}`);
      return new Response(
        JSON.stringify({ questions: poi.quiz_questions, cached: true }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (contentType === "game-event") {
      const eventField = `game_event_${eventType}`;
      if (poi[eventField]) {
        console.log(`Game event '${eventType}' already exists for POI: ${poi.name}`);
        return new Response(
          JSON.stringify({ event: poi[eventField], cached: true }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
    }

    // Initialize Anthropic client
    const anthropicApiKey = Deno.env.get("ANTHROPIC_API_KEY");
    if (!anthropicApiKey) {
      return new Response(
        JSON.stringify({ error: "ANTHROPIC_API_KEY not configured" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const client = new Anthropic({ apiKey: anthropicApiKey });

    // Generate content based on type
    if (contentType === "quiz") {
      const result = await generateQuiz(client, poi);

      // Save to database
      const { error: updateError } = await supabase
        .from('pois')
        .update({
          quiz_questions: result.questions,
          quiz_generated_at: new Date().toISOString(),
          ai_enriched_at: new Date().toISOString()
        })
        .eq('id', poiId);

      if (updateError) {
        console.error("Failed to save quiz:", updateError);
      }

      return new Response(
        JSON.stringify(result),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (contentType === "game-event" && eventType) {
      let result: MysteryEvent | TreasureEvent | TimetravelEvent;
      let updateField: string;

      switch (eventType) {
        case "mystery":
          result = await generateMysteryEvent(client, poi);
          updateField = "game_event_mystery";
          break;
        case "treasure":
          result = await generateTreasureEvent(client, poi);
          updateField = "game_event_treasure";
          break;
        case "timetravel":
          result = await generateTimetravelEvent(client, poi);
          updateField = "game_event_timetravel";
          break;
        default:
          throw new Error("Invalid event type");
      }

      // Save to database
      const { error: updateError } = await supabase
        .from('pois')
        .update({
          [updateField]: result,
          ai_enriched_at: new Date().toISOString()
        })
        .eq('id', poiId);

      if (updateError) {
        console.error(`Failed to save ${eventType} event:`, updateError);
      }

      return new Response(
        JSON.stringify({ event: result }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({ error: "Invalid request" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    console.error("Error enriching POI:", error);
    return new Response(
      JSON.stringify({ error: error.message || "Failed to enrich POI" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});

// Generate quiz questions for a POI
async function generateQuiz(client: Anthropic, poi: { name: string; category: string; description?: string; city?: string }): Promise<{ questions: QuizQuestion[] }> {
  const locationContext = poi.city ? ` in ${poi.city}` : "";
  const categoryText = poi.category ? ` (Kategorie: ${poi.category})` : "";

  const prompt = `Erstelle ein Quiz mit 5 Multiple-Choice-Fragen zur Sehenswürdigkeit "${poi.name}"${locationContext}${categoryText}.

Beschreibung: ${poi.description || "Keine Beschreibung verfügbar"}

Regeln:
- Die Fragen sollen interessante Fakten über die Sehenswürdigkeit abfragen
- Jede Frage hat genau 4 Antwortmöglichkeiten (A, B, C, D)
- Genau eine Antwort ist korrekt
- Die Fragen sollen lehrreich und unterhaltsam sein
- Alle Texte auf Deutsch

Antworte NUR mit validem JSON in diesem Format:
{"questions": [{"question": "Frage hier?", "answers": ["Antwort A", "Antwort B", "Antwort C", "Antwort D"], "correctAnswerIndex": 0}]}

Wichtig: Gib NUR das JSON zurück, keine Erklärungen oder Markdown.`;

  console.log(`Generating quiz for POI: ${poi.name}`);

  const response = await client.messages.create({
    model: "claude-sonnet-4-20250514",
    max_tokens: 1500,
    messages: [{ role: "user", content: prompt }]
  });

  const textContent = response.content.find(block => block.type === "text");
  if (!textContent || textContent.type !== "text") {
    throw new Error("No text response from Claude");
  }

  let jsonText = textContent.text.trim();
  jsonText = cleanJsonResponse(jsonText);

  const result = JSON.parse(jsonText);
  validateQuizStructure(result);

  return result;
}

// Generate a mystery/crime game event
async function generateMysteryEvent(client: Anthropic, poi: { name: string; category: string; description?: string; city?: string }): Promise<MysteryEvent> {
  const locationContext = poi.city ? ` in ${poi.city}` : "";

  const prompt = `Erstelle ein spannendes Krimi-Rätsel für die Sehenswürdigkeit "${poi.name}"${locationContext}.

Beschreibung: ${poi.description || "Eine interessante Sehenswürdigkeit"}

Erstelle eine fiktive Krimi-Geschichte, die an diesem Ort spielt. Die Geschichte sollte:
- Eine mysteriöse Situation beschreiben (z.B. ein verschwundenes Artefakt, ein rätselhafter Vorfall)
- 3-4 Hinweise enthalten, die der Spieler vor Ort "finden" kann
- Eine logische Lösung haben

Antworte NUR mit validem JSON in diesem Format:
{
  "story": "Die Einleitung der Geschichte (2-3 Sätze)",
  "clues": ["Hinweis 1", "Hinweis 2", "Hinweis 3"],
  "solution": "Die Auflösung des Rätsels"
}

Alle Texte auf Deutsch. Gib NUR das JSON zurück.`;

  const response = await client.messages.create({
    model: "claude-sonnet-4-20250514",
    max_tokens: 1000,
    messages: [{ role: "user", content: prompt }]
  });

  const textContent = response.content.find(block => block.type === "text");
  if (!textContent || textContent.type !== "text") {
    throw new Error("No text response from Claude");
  }

  let jsonText = textContent.text.trim();
  jsonText = cleanJsonResponse(jsonText);

  return JSON.parse(jsonText);
}

// Generate a treasure hunt game event
async function generateTreasureEvent(client: Anthropic, poi: { name: string; category: string; description?: string; city?: string }): Promise<TreasureEvent> {
  const locationContext = poi.city ? ` in ${poi.city}` : "";

  const prompt = `Erstelle ein Schatzsuche-Rätsel für die Sehenswürdigkeit "${poi.name}"${locationContext}.

Beschreibung: ${poi.description || "Eine interessante Sehenswürdigkeit"}

Erstelle ein Rätsel, das:
- Den Spieler zu diesem Ort führt oder hier eine Aufgabe stellt
- Einen kryptischen Hinweis auf den nächsten Ort enthält
- Spannend und altersgerecht für Familien ist

Antworte NUR mit validem JSON in diesem Format:
{
  "riddle": "Das Rätsel, das der Spieler lösen muss (2-3 Sätze)",
  "nextPoiHint": "Ein kryptischer Hinweis auf den nächsten Ort"
}

Alle Texte auf Deutsch. Gib NUR das JSON zurück.`;

  const response = await client.messages.create({
    model: "claude-sonnet-4-20250514",
    max_tokens: 500,
    messages: [{ role: "user", content: prompt }]
  });

  const textContent = response.content.find(block => block.type === "text");
  if (!textContent || textContent.type !== "text") {
    throw new Error("No text response from Claude");
  }

  let jsonText = textContent.text.trim();
  jsonText = cleanJsonResponse(jsonText);

  return JSON.parse(jsonText);
}

// Generate a time travel game event
async function generateTimetravelEvent(client: Anthropic, poi: { name: string; category: string; description?: string; city?: string }): Promise<TimetravelEvent> {
  const locationContext = poi.city ? ` in ${poi.city}` : "";

  const prompt = `Erstelle ein Zeitreise-Erlebnis für die Sehenswürdigkeit "${poi.name}"${locationContext}.

Beschreibung: ${poi.description || "Eine interessante Sehenswürdigkeit"}

Erstelle ein historisches Erlebnis, das:
- Den Spieler in eine bestimmte Epoche versetzt
- 3-4 interessante historische Fakten über diesen Ort enthält
- Ein spannendes "Was wäre wenn...?" Szenario beschreibt

Antworte NUR mit validem JSON in diesem Format:
{
  "era": "Die historische Epoche (z.B. 'Mittelalter, 1350')",
  "historicalFacts": ["Fakt 1", "Fakt 2", "Fakt 3"],
  "whatIf": "Ein alternatives Geschichtsszenario"
}

Alle Texte auf Deutsch. Gib NUR das JSON zurück.`;

  const response = await client.messages.create({
    model: "claude-sonnet-4-20250514",
    max_tokens: 800,
    messages: [{ role: "user", content: prompt }]
  });

  const textContent = response.content.find(block => block.type === "text");
  if (!textContent || textContent.type !== "text") {
    throw new Error("No text response from Claude");
  }

  let jsonText = textContent.text.trim();
  jsonText = cleanJsonResponse(jsonText);

  return JSON.parse(jsonText);
}

// Clean up potential markdown code blocks from JSON response
function cleanJsonResponse(text: string): string {
  if (text.startsWith("```json")) {
    text = text.slice(7);
  }
  if (text.startsWith("```")) {
    text = text.slice(3);
  }
  if (text.endsWith("```")) {
    text = text.slice(0, -3);
  }
  return text.trim();
}

// Validate quiz structure
function validateQuizStructure(quiz: { questions?: QuizQuestion[] }): void {
  if (!quiz.questions || !Array.isArray(quiz.questions) || quiz.questions.length === 0) {
    throw new Error("Invalid quiz structure");
  }

  for (const q of quiz.questions) {
    if (!q.question || !q.answers || q.answers.length !== 4 ||
        typeof q.correctAnswerIndex !== "number" ||
        q.correctAnswerIndex < 0 || q.correctAnswerIndex > 3) {
      throw new Error("Invalid question structure");
    }
  }
}
