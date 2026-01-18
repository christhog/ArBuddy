-- Migration: Create pois table for POI persistence
-- This replaces fetching POIs from Geoapify on every request

-- Enable required extensions
create extension if not exists "cube";
create extension if not exists "earthdistance";

-- Create pois table
create table if not exists pois (
  id uuid primary key default gen_random_uuid(),

  -- Geoapify Identification (for deduplication)
  geoapify_place_id text unique,

  -- Basic Data
  name text not null,
  description text,
  latitude double precision not null,
  longitude double precision not null,

  -- Original Geoapify Categories
  geoapify_categories text[],

  -- Our App Category
  category text not null check (category in ('landmark', 'nature', 'culture', 'entertainment', 'other')),

  -- Address Data
  street text,
  city text,
  country text,
  formatted_address text,

  -- AI-generated Content
  ai_category text,              -- Finer AI category
  ai_description text,           -- AI-generated description
  ai_facts jsonb,                -- Interesting facts ["Fact 1", "Fact 2", ...]

  -- Game Events (lazy loaded)
  game_event_mystery jsonb,      -- Mystery: {story, clues[], solution}
  game_event_treasure jsonb,     -- Treasure Hunt: {riddle, nextPoiHint}
  game_event_timetravel jsonb,   -- Time Travel: {era, historicalFacts[], whatIf}

  -- Quiz (migrated from quizzes table)
  quiz_questions jsonb,          -- Quiz questions
  quiz_generated_at timestamptz,

  -- Metadata
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  ai_enriched_at timestamptz     -- When AI content was generated
);

-- Spatial index for efficient location-based queries
create index if not exists idx_pois_location on pois using gist (
  ll_to_earth(latitude, longitude)
);

-- Index for category filtering
create index if not exists idx_pois_category on pois(category);

-- Index for geoapify_place_id lookups (for deduplication)
create index if not exists idx_pois_geoapify_id on pois(geoapify_place_id);

-- Index for name searches
create index if not exists idx_pois_name on pois(name);

-- Enable Row Level Security
alter table pois enable row level security;

-- RLS Policies for pois

-- Anyone can read POIs (public data)
create policy "Anyone can read pois"
  on pois for select
  to authenticated, anon
  using (true);

-- Only service role can insert POIs (Edge Function uses service key)
create policy "Service role can insert pois"
  on pois for insert
  to service_role
  with check (true);

-- Only service role can update POIs (Edge Function uses service key)
create policy "Service role can update pois"
  on pois for update
  to service_role
  using (true);

-- Function to update the updated_at timestamp
create or replace function update_pois_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

-- Trigger for auto-updating updated_at
drop trigger if exists trigger_pois_updated_at on pois;
create trigger trigger_pois_updated_at
  before update on pois
  for each row execute procedure update_pois_updated_at();

-- Function to find POIs within a radius (in meters)
create or replace function find_pois_in_radius(
  p_latitude double precision,
  p_longitude double precision,
  p_radius_meters double precision
)
returns setof pois as $$
begin
  return query
  select *
  from pois
  where earth_box(ll_to_earth(p_latitude, p_longitude), p_radius_meters) @> ll_to_earth(latitude, longitude)
    and earth_distance(ll_to_earth(p_latitude, p_longitude), ll_to_earth(latitude, longitude)) <= p_radius_meters;
end;
$$ language plpgsql stable;
