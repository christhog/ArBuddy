-- Add walk_radius and walk_speed columns to buddies table
ALTER TABLE buddies ADD COLUMN IF NOT EXISTS walk_radius FLOAT DEFAULT 1.5;
ALTER TABLE buddies ADD COLUMN IF NOT EXISTS walk_speed FLOAT DEFAULT 0.3;

-- Update existing buddies with sensible defaults
UPDATE buddies SET walk_radius = 1.5, walk_speed = 0.3 WHERE walk_radius IS NULL OR walk_speed IS NULL;
