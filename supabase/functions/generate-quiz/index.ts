import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Database format for quiz questions
interface QuizQuestion {
  question: string;
  answers: string[];
  correctAnswerIndex: number;
  explanation?: string;
}

interface QuizResponse {
  questions: QuizQuestion[];
}

// Perplexity response format
interface PerplexityQuizQuestion {
  frage: string;
  antworten: string[];
  korrekte_antwort: number; // 1-indexed
  erklaerung: string;
}

interface PerplexityResponse {
  name: string;
  kategorie: "Natur" | "Kultur" | "Entertainment" | "Landmark" | "Other";
  adresse: string;
  beschreibung: string;
  quiz: PerplexityQuizQuestion[];
}

// Result including AI-enriched data
interface EnrichedQuizResult {
  questions: QuizQuestion[];
  aiCategory?: string;
  aiDescription?: string;
}

Deno.serve(async (req) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { poiId, poiName, category } = await req.json();

    // Support both new (poiId) and legacy (poiName) API
    if (!poiId && !poiName) {
      return new Response(
        JSON.stringify({ error: "poiId or poiName is required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Initialize Supabase client
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // If poiId is provided, use the new POI-based approach
    if (poiId) {
      // Check if quiz already exists in POI record
      const { data: poi, error: poiError } = await supabase
        .from("pois")
        .select("id, name, category, description, city, quiz_questions")
        .eq("id", poiId)
        .single();

      if (poiError) {
        console.error("Error fetching POI:", poiError);
        return new Response(
          JSON.stringify({ error: "POI not found" }),
          { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      // Return cached quiz if exists
      if (poi.quiz_questions) {
        console.log(`Cache hit for POI ID: ${poiId}`);
        return new Response(
          JSON.stringify({ questions: poi.quiz_questions }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      // Generate new quiz with Perplexity
      const result = await generateQuizWithPerplexity(poi.name, poi.category, poi.description, poi.city);

      // Save to POI record including AI-enriched fields
      const now = new Date().toISOString();
      const updateData: Record<string, unknown> = {
        quiz_questions: result.questions,
        quiz_generated_at: now,
        ai_enriched_at: now
      };

      // Add AI-enriched fields if available
      if (result.aiCategory) {
        updateData.ai_category = result.aiCategory;
      }
      if (result.aiDescription) {
        updateData.ai_description = result.aiDescription;
      }

      const { error: updateError } = await supabase
        .from("pois")
        .update(updateData)
        .eq("id", poiId);

      if (updateError) {
        console.error("Failed to save quiz to POI:", updateError);
      } else {
        console.log(`Quiz and AI data saved to POI: ${poi.name}`);
      }

      return new Response(
        JSON.stringify({ questions: result.questions }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Legacy approach: use poiName with quizzes table
    // Check cache first in legacy quizzes table
    const { data: cached, error: cacheError } = await supabase
      .from("quizzes")
      .select("questions")
      .eq("poi_name", poiName)
      .single();

    if (cached && !cacheError) {
      console.log(`Cache hit for POI: ${poiName}`);
      return new Response(
        JSON.stringify({ questions: cached.questions }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Also check if there's a POI with this name that has a quiz
    const { data: poiByName } = await supabase
      .from("pois")
      .select("id, quiz_questions")
      .eq("name", poiName)
      .single();

    if (poiByName?.quiz_questions) {
      console.log(`Cache hit in pois table for: ${poiName}`);
      return new Response(
        JSON.stringify({ questions: poiByName.quiz_questions }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Generate new quiz
    const result = await generateQuizWithPerplexity(poiName, category);

    // Cache in legacy quizzes table for backwards compatibility
    const { error: insertError } = await supabase
      .from("quizzes")
      .insert({
        poi_name: poiName,
        questions: result.questions
      });

    if (insertError) {
      console.error("Failed to cache quiz:", insertError);
    } else {
      console.log(`Quiz cached for POI: ${poiName}`);
    }

    // If POI exists, also update its fields for consistency
    if (poiByName?.id) {
      const now = new Date().toISOString();
      const updateData: Record<string, unknown> = {
        quiz_questions: result.questions,
        quiz_generated_at: now,
        ai_enriched_at: now
      };
      if (result.aiCategory) {
        updateData.ai_category = result.aiCategory;
      }
      if (result.aiDescription) {
        updateData.ai_description = result.aiDescription;
      }

      const { error: poiUpdateError } = await supabase
        .from("pois")
        .update(updateData)
        .eq("id", poiByName.id);

      if (poiUpdateError) {
        console.error("Failed to update POI fields:", poiUpdateError);
      } else {
        console.log(`POI fields updated for: ${poiName}`);
      }
    }

    return new Response(
      JSON.stringify({ questions: result.questions }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    console.error("Error generating quiz:", error);
    return new Response(
      JSON.stringify({ error: error.message || "Failed to generate quiz" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});

async function generateQuizWithPerplexity(
  poiName: string,
  category?: string,
  description?: string,
  city?: string
): Promise<EnrichedQuizResult> {
  const perplexityApiKey = Deno.env.get("PERPLEXITY_API_KEY");
  if (!perplexityApiKey) {
    throw new Error("PERPLEXITY_API_KEY not configured");
  }

  const categoryText = category ? ` (Kategorie: ${category})` : "";
  const locationContext = city ? ` in ${city}` : "";
  const descriptionContext = description ? `\nBekannte Beschreibung: ${description}` : "";

  const prompt = `Recherchiere die Sehenswürdigkeit "${poiName}"${locationContext}${categoryText}.${descriptionContext}

Erstelle eine ausführliche Antwort mit folgenden Informationen:
1. Eine detaillierte Beschreibung der Sehenswürdigkeit (mindestens 2-3 Sätze)
2. Die passende Kategorie
3. Ein Quiz mit 5 interessanten Multiple-Choice-Fragen

Antworte NUR mit validem JSON in exakt diesem Format:
{
  "name": "${poiName}",
  "kategorie": "Natur|Kultur|Entertainment|Landmark|Other",
  "adresse": "Vollständige Adresse falls bekannt, sonst leer",
  "beschreibung": "Ausführliche Beschreibung der Sehenswürdigkeit...",
  "quiz": [
    {
      "frage": "Interessante Frage über die Sehenswürdigkeit?",
      "antworten": ["Antwort A", "Antwort B", "Antwort C", "Antwort D"],
      "korrekte_antwort": 1,
      "erklaerung": "Kurze Erklärung warum diese Antwort korrekt ist"
    }
  ]
}

Regeln:
- Wähle EINE Kategorie: Natur, Kultur, Entertainment, Landmark oder Other
- Das Quiz muss genau 5 Fragen haben
- Jede Frage hat genau 4 Antwortmöglichkeiten
- korrekte_antwort ist 1-4 (1=erste Antwort, 2=zweite, etc.)
- Alle Texte auf Deutsch
- Die Fragen sollen interessante, lehrreiche Fakten abfragen
- Gib NUR das JSON zurück, keine Erklärungen oder Markdown`;

  console.log(`Generating quiz with Perplexity for POI: ${poiName}`);

  const response = await fetch("https://api.perplexity.ai/chat/completions", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${perplexityApiKey}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      model: "sonar",
      messages: [
        {
          role: "system",
          content: "Du bist ein Experte für Sehenswürdigkeiten und Tourismus. Du antwortest immer auf Deutsch und ausschließlich mit validem JSON ohne zusätzlichen Text oder Markdown-Formatierung."
        },
        {
          role: "user",
          content: prompt
        }
      ],
      max_tokens: 2000,
      temperature: 0.2
    })
  });

  if (!response.ok) {
    const errorText = await response.text();
    console.error("Perplexity API error:", response.status, errorText);
    throw new Error(`Perplexity API error: ${response.status}`);
  }

  const data = await response.json();

  // Extract text response
  const textContent = data.choices?.[0]?.message?.content;
  if (!textContent) {
    throw new Error("No text response from Perplexity");
  }

  // Parse JSON from response
  let perplexityData: PerplexityResponse;
  try {
    // Clean up potential markdown code blocks
    let jsonText = textContent.trim();
    if (jsonText.startsWith("```json")) {
      jsonText = jsonText.slice(7);
    }
    if (jsonText.startsWith("```")) {
      jsonText = jsonText.slice(3);
    }
    if (jsonText.endsWith("```")) {
      jsonText = jsonText.slice(0, -3);
    }
    jsonText = jsonText.trim();

    perplexityData = JSON.parse(jsonText);
  } catch {
    console.error("Failed to parse Perplexity response:", textContent);
    throw new Error("Invalid JSON response from Perplexity");
  }

  // Validate response structure
  if (!perplexityData.quiz || !Array.isArray(perplexityData.quiz) || perplexityData.quiz.length === 0) {
    throw new Error("Invalid quiz structure in Perplexity response");
  }

  // Map Perplexity format to database format
  const questions: QuizQuestion[] = perplexityData.quiz.map(q => {
    // Validate question structure
    if (!q.frage || !q.antworten || q.antworten.length !== 4 ||
        typeof q.korrekte_antwort !== "number" ||
        q.korrekte_antwort < 1 || q.korrekte_antwort > 4) {
      throw new Error("Invalid question structure in Perplexity response");
    }

    return {
      question: q.frage,
      answers: q.antworten,
      correctAnswerIndex: q.korrekte_antwort - 1, // Convert 1-indexed to 0-indexed
      explanation: q.erklaerung
    };
  });

  return {
    questions,
    aiCategory: perplexityData.kategorie,
    aiDescription: perplexityData.beschreibung
  };
}
