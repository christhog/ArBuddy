import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

interface GeoapifyFeature {
  properties: {
    place_id?: string;
    name?: string;
    categories?: string[];
    street?: string;
    city?: string;
    country?: string;
    formatted?: string;
  };
  geometry: {
    type: string;
    coordinates: number[]; // [lon, lat]
  };
}

interface GeoapifyResponse {
  features: GeoapifyFeature[];
}

interface DatabasePOI {
  id: string;
  geoapify_place_id: string | null;
  name: string;
  description: string | null;
  latitude: number;
  longitude: number;
  category: string;
  geoapify_categories: string[] | null;
  street: string | null;
  city: string | null;
  country: string | null;
  formatted_address: string | null;
  ai_category: string | null;
  ai_description: string | null;
  ai_facts: string[] | null;
  quiz_questions: unknown | null;
  created_at: string;
}

interface POIResponse {
  id: string;
  name: string;
  description: string;
  category: string;
  latitude: number;
  longitude: number;
  geoapifyCategories: string[];
  street: string | null;
  city: string | null;
  hasQuiz: boolean;
  aiFacts: string[] | null;
}

Deno.serve(async (req) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { latitude, longitude, radius, userId } = await req.json();

    // Validate input
    if (typeof latitude !== "number" || typeof longitude !== "number") {
      return new Response(
        JSON.stringify({ error: "latitude and longitude are required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const searchRadius = radius || 5000;

    // Initialize Supabase client
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // ========== DB-FIRST: Step 1 - Load POIs from database within radius ==========
    console.log(`DB-First: Searching for POIs in database near (${latitude}, ${longitude}) within ${searchRadius}m`);

    const { data: dbPOIs, error: dbError } = await supabase
      .rpc('pois_within_radius', {
        lat: latitude,
        lon: longitude,
        radius_meters: searchRadius
      });

    if (dbError) {
      console.error("Database RPC error:", dbError);
    }

    const existingDBPOIs: DatabasePOI[] = dbPOIs || [];
    console.log(`Found ${existingDBPOIs.length} POIs in database for this area`);

    // Create a map of existing POIs by place_id for quick lookup
    const existingPOIMap = new Map<string, DatabasePOI>();
    for (const poi of existingDBPOIs) {
      if (poi.geoapify_place_id) {
        existingPOIMap.set(poi.geoapify_place_id, poi);
      }
    }

    // ========== Step 2 - Always fetch from Geoapify to discover new POIs ==========
    const shouldFetchFromGeoapify = true; // Always call Geoapify
    let geoapifyFetched = false;
    let geoapifyCount = 0;
    let insertedCount = 0;

    if (shouldFetchFromGeoapify) {
      console.log(`Fetching from Geoapify to discover new POIs (${existingDBPOIs.length} already in DB)...`);

      const geoapifyApiKey = Deno.env.get("GEOAPIFY_API_KEY");
      if (!geoapifyApiKey) {
        console.warn("GEOAPIFY_API_KEY not configured, skipping Geoapify fetch");
      } else {
        // Fetch from Geoapify
        const categories = [
          // Sehenswürdigkeiten & Attraktionen
          "tourism.sights",
          "tourism.attraction",

          // Kultur & Museen
          "entertainment.museum",
          "entertainment.culture",
          "entertainment.zoo",
          "entertainment.aquarium",
          "entertainment.theme_park",
          "entertainment.activity_park",

          // Historisches
          "heritage",
          "building.historic",

          // Gedenkstätten
          "memorial",

          // Natur & Parks
          "national_park",
          "natural.mountain",
          "natural.protected_area",
          "natural.water",
          "leisure.park",

          // Interessante Bauwerke
          "man_made.lighthouse",
          "man_made.windmill",
          "man_made.bridge",
          "man_made.tower",

          // Sport/Freizeit (nicht-kommerziell)
          "sport.stadium",
          "sport.swimming_pool",

          // Camping & Strand
          "camping",
          "beach"
        ].join(",");

        // Bounding Box berechnen (rect funktioniert zuverlässiger als circle)
        // 1 Grad Latitude ≈ 111km, 1 Grad Longitude ≈ 111km * cos(lat)
        const latOffset = searchRadius / 111000; // Radius in Grad
        const lonOffset = searchRadius / (111000 * Math.cos(latitude * Math.PI / 180));

        const minLon = longitude - lonOffset;
        const maxLon = longitude + lonOffset;
        const minLat = latitude - latOffset;
        const maxLat = latitude + latOffset;

        const filter = `rect:${minLon},${maxLat},${maxLon},${minLat}`;

        const url = new URL("https://api.geoapify.com/v2/places");
        url.searchParams.set("categories", categories);
        url.searchParams.set("filter", filter);
        url.searchParams.set("limit", "100");
        url.searchParams.set("apiKey", geoapifyApiKey);

        // Log full URL (mit maskiertem API key)
        console.log(`Geoapify request: ${url.toString().replace(geoapifyApiKey, '***')}`);

        const response = await fetch(url.toString());

        if (!response.ok) {
          const errorBody = await response.text();
          console.error(`Geoapify error (${response.status}): ${errorBody}`);
        } else {
          const data: GeoapifyResponse = await response.json();
          geoapifyCount = data.features.length;
          geoapifyFetched = true;
          console.log(`Received ${geoapifyCount} POIs from Geoapify`);

          // Process Geoapify results
          const geoapifyPOIs = data.features.map(feature => {
            const props = feature.properties;
            const coords = feature.geometry.coordinates;

            const placeId = props.place_id ||
              `geo_${coords[1].toFixed(6)}_${coords[0].toFixed(6)}_${(props.name || 'unnamed').replace(/\s+/g, '_').toLowerCase()}`;

            const name = props.name || generateFallbackName(props.categories, props.city) || props.formatted || "Unbekannter Ort";

            return {
              placeId,
              name,
              description: buildDescription(props),
              latitude: coords[1],
              longitude: coords[0],
              category: determineCategory(props.categories),
              geoapifyCategories: props.categories || [],
              street: props.street || null,
              city: props.city || null,
              country: props.country || null,
              formattedAddress: props.formatted || null,
            };
          });

          // Insert new POIs that don't exist yet
          const newPOIsToInsert = geoapifyPOIs
            .filter(p => !existingPOIMap.has(p.placeId))
            .map(p => ({
              geoapify_place_id: p.placeId,
              name: p.name,
              description: p.description,
              latitude: p.latitude,
              longitude: p.longitude,
              category: p.category,
              geoapify_categories: p.geoapifyCategories,
              street: p.street,
              city: p.city,
              country: p.country,
              formatted_address: p.formattedAddress,
            }));

          if (newPOIsToInsert.length > 0) {
            console.log(`Inserting ${newPOIsToInsert.length} new POIs into database`);

            const { data: insertedPOIs, error: insertError } = await supabase
              .from('pois')
              .insert(newPOIsToInsert)
              .select();

            if (insertError) {
              console.error("Insert error:", insertError);
            } else if (insertedPOIs) {
              insertedCount = insertedPOIs.length;
              console.log(`Successfully inserted ${insertedCount} new POIs`);

              // Add inserted POIs to existing list
              for (const poi of insertedPOIs) {
                existingDBPOIs.push(poi);
                if (poi.geoapify_place_id) {
                  existingPOIMap.set(poi.geoapify_place_id, poi);
                }
              }
            }
          } else {
            console.log("No new POIs to insert from Geoapify");
          }
        }
      }
    }

    // ========== Step 3 - Get user progress if userId is provided ==========
    const userProgressMap = new Map<string, {
      visitCompleted: boolean;
      photoCompleted: boolean;
      arCompleted: boolean;
      quizCompleted: boolean;
      quizScore: number | null;
    }>();

    if (userId) {
      const poiIds = existingDBPOIs.map(p => p.id);

      if (poiIds.length > 0) {
        const { data: progressData } = await supabase
          .from('user_poi_progress')
          .select('poi_id, visit_completed, photo_completed, ar_completed, quiz_completed, quiz_score')
          .eq('user_id', userId)
          .in('poi_id', poiIds);

        if (progressData) {
          for (const p of progressData) {
            userProgressMap.set(p.poi_id, {
              visitCompleted: p.visit_completed,
              photoCompleted: p.photo_completed,
              arCompleted: p.ar_completed,
              quizCompleted: p.quiz_completed,
              quizScore: p.quiz_score,
            });
          }
          console.log(`Loaded progress for ${userProgressMap.size} POIs`);
        }
      }
    }

    // ========== Step 4 - Build response from database POIs ==========
    const pois: (POIResponse & { userProgress?: { visitCompleted: boolean; photoCompleted: boolean; arCompleted: boolean; quizCompleted: boolean; quizScore: number | null } })[] = [];

    for (const dbPOI of existingDBPOIs) {
      const result: POIResponse & { userProgress?: { visitCompleted: boolean; photoCompleted: boolean; arCompleted: boolean; quizCompleted: boolean; quizScore: number | null } } = {
        id: dbPOI.id,
        name: dbPOI.name, // Uses the DB name (possibly improved/corrected)
        description: dbPOI.ai_description || dbPOI.description || "Ein interessanter Ort zum Entdecken",
        category: dbPOI.category,
        latitude: dbPOI.latitude,
        longitude: dbPOI.longitude,
        geoapifyCategories: dbPOI.geoapify_categories || [],
        street: dbPOI.street,
        city: dbPOI.city,
        hasQuiz: dbPOI.quiz_questions !== null,
        aiFacts: dbPOI.ai_facts,
      };

      // Add user progress if available
      const progress = userProgressMap.get(dbPOI.id);
      if (progress) {
        result.userProgress = progress;
      }

      pois.push(result);
    }

    console.log(`Returning ${pois.length} total POIs (DB-First)`);

    return new Response(
      JSON.stringify({
        pois,
        _debug: {
          dbFirst: true,
          existingInDB: existingDBPOIs.length - insertedCount,
          geoapifyFetched,
          geoapifyCount,
          newlyInserted: insertedCount,
          finalCount: pois.length,
        }
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    console.error("Error fetching POIs:", error);
    return new Response(
      JSON.stringify({ error: error.message || "Failed to fetch POIs" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});

const categoryNames: Record<string, string> = {
  // Sehenswürdigkeiten
  "tourism.sights": "Sehenswürdigkeit",
  "tourism.attraction": "Attraktion",

  // Kultur & Museen
  "entertainment.museum": "Museum",
  "entertainment.culture": "Kulturstätte",
  "entertainment.zoo": "Zoo",
  "entertainment.aquarium": "Aquarium",
  "entertainment.theme_park": "Freizeitpark",
  "entertainment.activity_park": "Aktivitätspark",

  // Historisches
  "heritage": "Historischer Ort",
  "heritage.castle": "Burg/Schloss",
  "building.historic": "Historisches Gebäude",

  // Gedenkstätten
  "memorial": "Gedenkstätte",
  "memorial.cemetery": "Friedhof",

  // Natur & Parks
  "national_park": "Nationalpark",
  "natural.mountain": "Berg",
  "natural.mountain.peak": "Berggipfel",
  "natural.protected_area": "Naturschutzgebiet",
  "natural.water": "Gewässer",
  "leisure.park": "Park",
  "leisure.garden": "Garten",

  // Interessante Bauwerke
  "man_made.lighthouse": "Leuchtturm",
  "man_made.windmill": "Windmühle",
  "man_made.bridge": "Brücke",
  "man_made.tower": "Turm",

  // Sport/Freizeit
  "sport.stadium": "Stadion",
  "sport.swimming_pool": "Schwimmbad",

  // Camping & Strand
  "camping": "Campingplatz",
  "beach": "Strand",
};

function generateFallbackName(categories?: string[], city?: string): string | null {
  if (!categories || categories.length === 0) return null;

  let bestMatch: string | null = null;

  for (const cat of categories) {
    if (categoryNames[cat]) {
      bestMatch = categoryNames[cat];
      break;
    }
    for (const [key, value] of Object.entries(categoryNames)) {
      if (cat.startsWith(key + ".") || cat === key) {
        bestMatch = value;
        break;
      }
    }
    if (bestMatch) break;
  }

  if (!bestMatch) return null;

  if (city) {
    return `${bestMatch} in ${city}`;
  }

  return bestMatch;
}

function buildDescription(props: GeoapifyFeature["properties"]): string {
  const parts: string[] = [];

  if (props.categories) {
    for (const cat of props.categories) {
      // Natur & Wandern
      if (cat.includes("hiking") || cat.includes("trail")) {
        parts.push("Wanderweg");
        break;
      } else if (cat.includes("peak") || cat.includes("mountain")) {
        parts.push("Berg");
        break;
      } else if (cat.includes("cave")) {
        parts.push("Höhle");
        break;
      } else if (cat.includes("national_park")) {
        parts.push("Nationalpark");
        break;
      } else if (cat.includes("protected_area")) {
        parts.push("Naturschutzgebiet");
        break;
      } else if (cat.includes("beach")) {
        parts.push("Strand");
        break;
      } else if (cat.includes("camping")) {
        parts.push("Campingplatz");
        break;
      }
      // Sehenswürdigkeiten
      else if (cat.includes("castle")) {
        parts.push("Burg/Schloss");
        break;
      } else if (cat.includes("lighthouse")) {
        parts.push("Leuchtturm");
        break;
      } else if (cat.includes("windmill")) {
        parts.push("Windmühle");
        break;
      } else if (cat.includes("man_made.bridge")) {
        parts.push("Brücke");
        break;
      } else if (cat.includes("man_made.tower")) {
        parts.push("Turm");
        break;
      } else if (cat.includes("church")) {
        parts.push("Kirche");
        break;
      } else if (cat.includes("heritage") || cat.includes("historic")) {
        parts.push("Historische Sehenswürdigkeit");
        break;
      }
      // Kultur
      else if (cat.includes("museum")) {
        parts.push("Museum");
        break;
      } else if (cat.includes("aquarium")) {
        parts.push("Aquarium");
        break;
      } else if (cat.includes("memorial") || cat.includes("cemetery")) {
        parts.push("Gedenkstätte");
        break;
      } else if (cat.includes("viewpoint")) {
        parts.push("Aussichtspunkt");
        break;
      }
      // Parks & Gärten
      else if (cat.includes("park")) {
        parts.push("Park");
        break;
      } else if (cat.includes("garden")) {
        parts.push("Garten");
        break;
      } else if (cat.includes("water") || cat.includes("lake") || cat.includes("fountain")) {
        parts.push("Gewässer");
        break;
      }
      // Unterhaltung & Sport
      else if (cat.includes("zoo")) {
        parts.push("Zoo");
        break;
      } else if (cat.includes("theme_park")) {
        parts.push("Freizeitpark");
        break;
      } else if (cat.includes("activity_park")) {
        parts.push("Aktivitätspark");
        break;
      } else if (cat.includes("stadium")) {
        parts.push("Stadion");
        break;
      } else if (cat.includes("swimming_pool")) {
        parts.push("Schwimmbad");
        break;
      }
    }
  }

  const addressParts: string[] = [];
  if (props.street) addressParts.push(props.street);
  if (props.city) addressParts.push(props.city);
  if (addressParts.length > 0) {
    parts.push(addressParts.join(", "));
  }

  return parts.length > 0 ? parts.join(" • ") : "Ein interessanter Ort zum Entdecken";
}

function determineCategory(categories?: string[]): string {
  if (!categories) return "other";

  for (const cat of categories) {
    // Sehenswürdigkeiten & Historisches
    if (cat.includes("heritage") || cat.includes("tourism.sights") ||
        cat.includes("tourism.attraction") || cat.includes("castle") ||
        cat.includes("viewpoint") || cat.includes("building.historic") ||
        cat.includes("man_made.lighthouse") || cat.includes("man_made.tower") ||
        cat.includes("man_made.bridge") || cat.includes("man_made.windmill")) {
      return "landmark";
    }

    // Kultur & Gedenkstätten
    if (cat.includes("museum") || cat.includes("culture") ||
        cat.includes("church") || cat.includes("memorial") ||
        cat.includes("aquarium")) {
      return "culture";
    }

    // Natur
    if (cat.includes("natural") || cat.includes("park") ||
        cat.includes("national_park") || cat.includes("protected_area") ||
        cat.includes("mountain") || cat.includes("water") ||
        cat.includes("peak") || cat.includes("garden") ||
        cat.includes("beach") || cat.includes("camping")) {
      return "nature";
    }

    // Unterhaltung & Sport
    if (cat.includes("zoo") || cat.includes("theme_park") ||
        cat.includes("activity_park") || cat.includes("stadium") ||
        cat.includes("swimming_pool") || cat.includes("entertainment")) {
      return "entertainment";
    }
  }

  return "other";
}
