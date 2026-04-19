-- Migration: Create poi_quests table for POI-bound quests
-- Quest types: visit, photo, quiz (nature POIs only get visit)

create table if not exists poi_quests (
  id uuid primary key default gen_random_uuid(),
  poi_id uuid not null references pois(id) on delete cascade,
  quest_type text not null check (quest_type in ('visit', 'photo', 'quiz')),
  title text not null,
  description text,
  xp_reward integer not null default 50,
  difficulty text not null default 'easy' check (difficulty in ('easy', 'medium', 'hard')),
  created_at timestamptz default now(),

  -- Only one quest per type per POI
  unique(poi_id, quest_type)
);

-- Index for efficient POI lookups
create index if not exists idx_poi_quests_poi_id on poi_quests(poi_id);

-- Index for quest type filtering
create index if not exists idx_poi_quests_quest_type on poi_quests(quest_type);

-- Enable Row Level Security
alter table poi_quests enable row level security;

-- RLS Policies for poi_quests

-- Anyone can read POI quests (public data)
create policy "Anyone can read poi_quests"
  on poi_quests for select
  to authenticated, anon
  using (true);

-- Only service role can insert quests (Edge Function uses service key)
create policy "Service role can insert poi_quests"
  on poi_quests for insert
  to service_role
  with check (true);

-- Only service role can update quests
create policy "Service role can update poi_quests"
  on poi_quests for update
  to service_role
  using (true);

-- Only service role can delete quests
create policy "Service role can delete poi_quests"
  on poi_quests for delete
  to service_role
  using (true);

-- Function to generate quests for a POI based on its category
create or replace function generate_poi_quests(p_poi_id uuid)
returns void as $$
declare
  v_poi record;
  v_quest_types text[];
  v_quest_type text;
  v_title text;
  v_description text;
  v_xp_reward integer;
  v_difficulty text;
begin
  -- Get the POI
  select * into v_poi from pois where id = p_poi_id;

  if not found then
    raise exception 'POI not found: %', p_poi_id;
  end if;

  -- Determine quest types based on category
  -- nature: only visit
  -- landmark: visit, photo, quiz (photo only for landmarks!)
  -- others (culture, entertainment, other): visit, quiz
  if v_poi.category = 'nature' then
    v_quest_types := array['visit'];
  elsif v_poi.category = 'landmark' then
    v_quest_types := array['visit', 'photo', 'quiz'];
  else
    v_quest_types := array['visit', 'quiz'];
  end if;

  -- Generate quests for each type
  foreach v_quest_type in array v_quest_types loop
    -- Set quest properties based on type
    case v_quest_type
      when 'visit' then
        v_title := 'Entdecke ' || v_poi.name;
        v_description := 'Besuche ' || v_poi.name || ' und entdecke diesen interessanten Ort.';
        v_xp_reward := 50;
        v_difficulty := 'easy';
      when 'photo' then
        v_title := 'Fotografiere ' || v_poi.name;
        v_description := 'Mache ein Foto von ' || v_poi.name || ' und halte den Moment fest.';
        v_xp_reward := 75;
        v_difficulty := 'medium';
      when 'quiz' then
        v_title := 'Quiz über ' || v_poi.name;
        v_description := 'Beantworte Fragen über ' || v_poi.name || ' und teste dein Wissen.';
        v_xp_reward := 100;
        v_difficulty := 'hard';
    end case;

    -- Adjust difficulty based on POI category
    if v_poi.category in ('culture', 'landmark') then
      if v_difficulty = 'easy' then
        v_difficulty := 'medium';
      end if;
    end if;

    -- Insert the quest (ignore if already exists)
    insert into poi_quests (poi_id, quest_type, title, description, xp_reward, difficulty)
    values (p_poi_id, v_quest_type, v_title, v_description, v_xp_reward, v_difficulty)
    on conflict (poi_id, quest_type) do nothing;
  end loop;
end;
$$ language plpgsql security definer;

-- Function to generate quests for all existing POIs (one-time migration)
create or replace function generate_quests_for_all_pois()
returns integer as $$
declare
  v_poi record;
  v_count integer := 0;
begin
  for v_poi in select id from pois loop
    perform generate_poi_quests(v_poi.id);
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$ language plpgsql security definer;

-- Generate quests for all existing POIs
select generate_quests_for_all_pois();
