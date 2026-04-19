-- Migration: Create world_quests tables for AR experiences and area-based quests

-- Main world_quests table
create table if not exists world_quests (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  quest_type text not null default 'ar' check (quest_type in ('ar', 'exploration', 'collection')),
  xp_reward integer not null default 100,
  difficulty text not null default 'medium' check (difficulty in ('easy', 'medium', 'hard')),

  -- Geographic area (optional - for area-based quests)
  center_latitude double precision,
  center_longitude double precision,
  radius_meters double precision,

  -- Status
  is_active boolean default true,

  -- Metadata
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- Junction table for world quests linked to multiple POIs
create table if not exists world_quest_pois (
  world_quest_id uuid references world_quests(id) on delete cascade,
  poi_id uuid references pois(id) on delete cascade,
  primary key (world_quest_id, poi_id)
);

-- User progress for world quests
create table if not exists user_world_quest_progress (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  world_quest_id uuid not null references world_quests(id) on delete cascade,
  completed boolean default false,
  completed_at timestamptz,
  xp_earned integer default 0,

  -- Metadata
  created_at timestamptz default now(),
  updated_at timestamptz default now(),

  -- Ensure unique user-quest combination
  unique(user_id, world_quest_id)
);

-- Indexes for world_quests
create index if not exists idx_world_quests_is_active on world_quests(is_active);
create index if not exists idx_world_quests_quest_type on world_quests(quest_type);

-- Spatial index for location-based queries
create index if not exists idx_world_quests_location on world_quests using gist (
  ll_to_earth(center_latitude, center_longitude)
) where center_latitude is not null and center_longitude is not null;

-- Indexes for world_quest_pois
create index if not exists idx_world_quest_pois_quest on world_quest_pois(world_quest_id);
create index if not exists idx_world_quest_pois_poi on world_quest_pois(poi_id);

-- Indexes for user_world_quest_progress
create index if not exists idx_user_world_quest_progress_user on user_world_quest_progress(user_id);
create index if not exists idx_user_world_quest_progress_quest on user_world_quest_progress(world_quest_id);

-- Enable Row Level Security
alter table world_quests enable row level security;
alter table world_quest_pois enable row level security;
alter table user_world_quest_progress enable row level security;

-- RLS Policies for world_quests

-- Anyone can read world quests
create policy "Anyone can read world_quests"
  on world_quests for select
  to authenticated, anon
  using (true);

-- Only service role can manage world quests
create policy "Service role can manage world_quests"
  on world_quests for all
  to service_role
  using (true);

-- RLS Policies for world_quest_pois

-- Anyone can read world quest POI links
create policy "Anyone can read world_quest_pois"
  on world_quest_pois for select
  to authenticated, anon
  using (true);

-- Only service role can manage world quest POI links
create policy "Service role can manage world_quest_pois"
  on world_quest_pois for all
  to service_role
  using (true);

-- RLS Policies for user_world_quest_progress

-- Users can only view their own progress
create policy "Users can view own world quest progress"
  on user_world_quest_progress for select
  using (auth.uid() = user_id);

-- Users can insert their own progress records
create policy "Users can insert own world quest progress"
  on user_world_quest_progress for insert
  with check (auth.uid() = user_id);

-- Users can update their own progress records
create policy "Users can update own world quest progress"
  on user_world_quest_progress for update
  using (auth.uid() = user_id);

-- Service role has full access
create policy "Service role can manage world quest progress"
  on user_world_quest_progress for all
  to service_role
  using (true);

-- Trigger for auto-updating updated_at on world_quests
create or replace function update_world_quests_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists trigger_world_quests_updated_at on world_quests;
create trigger trigger_world_quests_updated_at
  before update on world_quests
  for each row execute procedure update_world_quests_updated_at();

-- Trigger for auto-updating updated_at on user_world_quest_progress
create or replace function update_user_world_quest_progress_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists trigger_user_world_quest_progress_updated_at on user_world_quest_progress;
create trigger trigger_user_world_quest_progress_updated_at
  before update on user_world_quest_progress
  for each row execute procedure update_user_world_quest_progress_updated_at();

-- Function to find world quests within a radius
create or replace function world_quests_within_radius(
  lat double precision,
  lon double precision,
  radius_meters double precision
)
returns setof world_quests as $$
begin
  return query
  select wq.*
  from world_quests wq
  where wq.is_active = true
    and wq.center_latitude is not null
    and wq.center_longitude is not null
    and earth_box(ll_to_earth(lat, lon), radius_meters) @> ll_to_earth(wq.center_latitude, wq.center_longitude)
    and earth_distance(ll_to_earth(lat, lon), ll_to_earth(wq.center_latitude, wq.center_longitude)) <= radius_meters;
end;
$$ language plpgsql stable;

-- Function to complete a world quest
create or replace function complete_world_quest(
  p_user_id uuid,
  p_world_quest_id uuid,
  p_xp_earned integer
)
returns user_world_quest_progress as $$
declare
  v_progress user_world_quest_progress;
begin
  -- Try to insert or get existing progress
  insert into user_world_quest_progress (user_id, world_quest_id, completed, completed_at, xp_earned)
  values (p_user_id, p_world_quest_id, true, now(), p_xp_earned)
  on conflict (user_id, world_quest_id) do update
  set completed = true,
      completed_at = coalesce(user_world_quest_progress.completed_at, now()),
      xp_earned = greatest(user_world_quest_progress.xp_earned, p_xp_earned)
  returning * into v_progress;

  return v_progress;
end;
$$ language plpgsql security definer;
