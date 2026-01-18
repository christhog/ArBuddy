-- Migration: Create user_poi_progress table for tracking user progress per POI
-- This allows tracking which quest types a user has completed at each POI

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
  quiz_score integer,            -- Number of correct answers

  -- XP earned for this POI
  total_xp_earned integer default 0,

  -- Metadata
  created_at timestamptz default now(),
  updated_at timestamptz default now(),

  -- Ensure unique user-poi combination
  unique(user_id, poi_id)
);

-- Indexes for efficient queries
create index if not exists idx_user_poi_progress_user on user_poi_progress(user_id);
create index if not exists idx_user_poi_progress_poi on user_poi_progress(poi_id);

-- Composite index for common queries
create index if not exists idx_user_poi_progress_user_poi on user_poi_progress(user_id, poi_id);

-- Enable Row Level Security
alter table user_poi_progress enable row level security;

-- RLS Policies for user_poi_progress

-- Users can only view their own progress
create policy "Users can view own poi progress"
  on user_poi_progress for select
  using (auth.uid() = user_id);

-- Users can insert their own progress records
create policy "Users can insert own poi progress"
  on user_poi_progress for insert
  with check (auth.uid() = user_id);

-- Users can update their own progress records
create policy "Users can update own poi progress"
  on user_poi_progress for update
  using (auth.uid() = user_id);

-- Service role has full access (for Edge Functions)
create policy "Service role can manage poi progress"
  on user_poi_progress for all
  to service_role
  using (true);

-- Function to update the updated_at timestamp
create or replace function update_user_poi_progress_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

-- Trigger for auto-updating updated_at
drop trigger if exists trigger_user_poi_progress_updated_at on user_poi_progress;
create trigger trigger_user_poi_progress_updated_at
  before update on user_poi_progress
  for each row execute procedure update_user_poi_progress_updated_at();

-- Function to get or create user progress for a POI
create or replace function get_or_create_poi_progress(
  p_user_id uuid,
  p_poi_id uuid
)
returns user_poi_progress as $$
declare
  v_progress user_poi_progress;
begin
  -- Try to get existing progress
  select * into v_progress
  from user_poi_progress
  where user_id = p_user_id and poi_id = p_poi_id;

  -- If not found, create new record
  if not found then
    insert into user_poi_progress (user_id, poi_id)
    values (p_user_id, p_poi_id)
    returning * into v_progress;
  end if;

  return v_progress;
end;
$$ language plpgsql security definer;

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
  select * into v_progress from get_or_create_poi_progress(p_user_id, p_poi_id);

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
      raise exception 'Unknown quest type: %', p_quest_type;
  end case;

  return v_progress;
end;
$$ language plpgsql security definer;

-- View for user statistics
create or replace view user_poi_statistics as
select
  user_id,
  count(*) as total_pois_visited,
  count(*) filter (where visit_completed and photo_completed and ar_completed and quiz_completed) as fully_completed_pois,
  sum(case when visit_completed then 1 else 0 end) as visit_quests_completed,
  sum(case when photo_completed then 1 else 0 end) as photo_quests_completed,
  sum(case when ar_completed then 1 else 0 end) as ar_quests_completed,
  sum(case when quiz_completed then 1 else 0 end) as quiz_quests_completed,
  sum(total_xp_earned) as total_poi_xp
from user_poi_progress
group by user_id;
