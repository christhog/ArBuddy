-- ARBuddy Database Schema
-- Run this in the Supabase SQL Editor

-- Users table (extends Supabase Auth)
create table if not exists users (
  id uuid primary key references auth.users(id) on delete cascade,
  email text unique not null,
  username text not null,
  xp integer default 0,
  level integer default 1,
  created_at timestamp with time zone default now()
);

-- Completed Quests tracking
create table if not exists completed_quests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade,
  quest_id text not null,
  poi_name text,
  completed_at timestamp with time zone default now(),
  xp_earned integer default 0,
  unique(user_id, quest_id)
);

-- Cached Quizzes (saves Claude API calls)
create table if not exists quizzes (
  id uuid primary key default gen_random_uuid(),
  poi_name text unique not null,
  questions jsonb not null,
  created_at timestamp with time zone default now()
);

-- Enable Row Level Security
alter table users enable row level security;
alter table completed_quests enable row level security;
alter table quizzes enable row level security;

-- Users: Users can only read/update their own profile
create policy "Users can view own profile"
  on users for select
  using (auth.uid() = id);

create policy "Users can update own profile"
  on users for update
  using (auth.uid() = id);

create policy "Users can insert own profile"
  on users for insert
  with check (auth.uid() = id);

-- Completed Quests: Users can only access their own completed quests
create policy "Users can view own completed quests"
  on completed_quests for select
  using (auth.uid() = user_id);

create policy "Users can insert own completed quests"
  on completed_quests for insert
  with check (auth.uid() = user_id);

-- Quizzes: Anyone can read cached quizzes (read by Edge Function)
create policy "Anyone can read quizzes"
  on quizzes for select
  to authenticated, anon
  using (true);

-- Only service role can insert/update quizzes (Edge Function uses service key)
create policy "Service role can manage quizzes"
  on quizzes for all
  to service_role
  using (true);

-- Function to auto-create user profile after signup
create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.users (id, email, username, xp, level)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1)),
    0,
    1
  );
  return new;
end;
$$ language plpgsql security definer;

-- Trigger for auto-creating user profile
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- Function to calculate level from XP
create or replace function calculate_level(xp_amount integer)
returns integer as $$
begin
  -- Level formula: level = floor(sqrt(xp / 100)) + 1
  -- Level 1: 0-99 XP, Level 2: 100-399 XP, Level 3: 400-899 XP, etc.
  return floor(sqrt(xp_amount::float / 100)) + 1;
end;
$$ language plpgsql immutable;

-- Function to add XP and update level
create or replace function add_xp(user_uuid uuid, xp_amount integer)
returns void as $$
declare
  new_xp integer;
  new_level integer;
begin
  update users
  set xp = xp + xp_amount
  where id = user_uuid
  returning xp into new_xp;

  new_level := calculate_level(new_xp);

  update users
  set level = new_level
  where id = user_uuid;
end;
$$ language plpgsql security definer;

-- Index for faster quiz lookups
create index if not exists idx_quizzes_poi_name on quizzes(poi_name);
create index if not exists idx_completed_quests_user_id on completed_quests(user_id);

-- =============================================================================
-- POI Persistence & User Progress Tables
-- =============================================================================

-- Enable required extensions for spatial queries
create extension if not exists "cube";
create extension if not exists "earthdistance";

-- POIs table for persistent POI storage
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
  ai_category text,
  ai_description text,
  ai_facts jsonb,

  -- Game Events (lazy loaded)
  game_event_mystery jsonb,
  game_event_treasure jsonb,
  game_event_timetravel jsonb,

  -- Quiz (migrated from quizzes table)
  quiz_questions jsonb,
  quiz_generated_at timestamptz,

  -- Metadata
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  ai_enriched_at timestamptz
);

-- User POI Progress table
create table if not exists user_poi_progress (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade not null,
  poi_id uuid references pois(id) on delete cascade not null,

  -- Quest-Type Completion
  visit_completed boolean default false,
  visit_completed_at timestamptz,

  photo_completed boolean default false,
  photo_completed_at timestamptz,

  ar_completed boolean default false,
  ar_completed_at timestamptz,

  quiz_completed boolean default false,
  quiz_completed_at timestamptz,
  quiz_score integer,

  -- XP earned for this POI
  total_xp_earned integer default 0,

  -- Metadata
  created_at timestamptz default now(),
  updated_at timestamptz default now(),

  unique(user_id, poi_id)
);

-- Indexes for pois
create index if not exists idx_pois_location on pois using gist (ll_to_earth(latitude, longitude));
create index if not exists idx_pois_category on pois(category);
create index if not exists idx_pois_geoapify_id on pois(geoapify_place_id);
create index if not exists idx_pois_name on pois(name);

-- Indexes for user_poi_progress
create index if not exists idx_user_poi_progress_user on user_poi_progress(user_id);
create index if not exists idx_user_poi_progress_poi on user_poi_progress(poi_id);

-- Enable RLS for new tables
alter table pois enable row level security;
alter table user_poi_progress enable row level security;

-- POIs RLS Policies
create policy "Anyone can read pois"
  on pois for select
  to authenticated, anon
  using (true);

create policy "Service role can insert pois"
  on pois for insert
  to service_role
  with check (true);

create policy "Service role can update pois"
  on pois for update
  to service_role
  using (true);

-- User POI Progress RLS Policies
create policy "Users can view own poi progress"
  on user_poi_progress for select
  using (auth.uid() = user_id);

create policy "Users can insert own poi progress"
  on user_poi_progress for insert
  with check (auth.uid() = user_id);

create policy "Users can update own poi progress"
  on user_poi_progress for update
  using (auth.uid() = user_id);

create policy "Service role can manage poi progress"
  on user_poi_progress for all
  to service_role
  using (true);

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

-- Function to complete a quest type for a POI
create or replace function complete_poi_quest(
  p_user_id uuid,
  p_poi_id uuid,
  p_quest_type text,
  p_xp_earned integer,
  p_quiz_score integer default null
)
returns user_poi_progress as $$
declare
  v_progress user_poi_progress;
begin
  -- Get or create progress record
  insert into user_poi_progress (user_id, poi_id)
  values (p_user_id, p_poi_id)
  on conflict (user_id, poi_id) do nothing;

  select * into v_progress
  from user_poi_progress
  where user_id = p_user_id and poi_id = p_poi_id;

  -- Update the appropriate quest type
  case p_quest_type
    when 'visit' then
      if not v_progress.visit_completed then
        update user_poi_progress
        set visit_completed = true,
            visit_completed_at = now(),
            total_xp_earned = total_xp_earned + p_xp_earned
        where id = v_progress.id
        returning * into v_progress;
      end if;
    when 'photo' then
      if not v_progress.photo_completed then
        update user_poi_progress
        set photo_completed = true,
            photo_completed_at = now(),
            total_xp_earned = total_xp_earned + p_xp_earned
        where id = v_progress.id
        returning * into v_progress;
      end if;
    when 'ar' then
      if not v_progress.ar_completed then
        update user_poi_progress
        set ar_completed = true,
            ar_completed_at = now(),
            total_xp_earned = total_xp_earned + p_xp_earned
        where id = v_progress.id
        returning * into v_progress;
      end if;
    when 'quiz', 'trivia' then
      if not v_progress.quiz_completed then
        update user_poi_progress
        set quiz_completed = true,
            quiz_completed_at = now(),
            quiz_score = p_quiz_score,
            total_xp_earned = total_xp_earned + p_xp_earned
        where id = v_progress.id
        returning * into v_progress;
      end if;
    else
      null; -- Ignore unknown quest types
  end case;

  return v_progress;
end;
$$ language plpgsql security definer;
