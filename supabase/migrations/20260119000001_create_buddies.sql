-- Buddies table
CREATE TABLE IF NOT EXISTS buddies (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  description TEXT,
  model_url TEXT NOT NULL,      -- z.B. "models/jessy.usdz"
  thumbnail_url TEXT,            -- z.B. "thumbnails/jessy.png"
  is_default BOOLEAN DEFAULT false,
  sort_order INTEGER DEFAULT 0,
  scale FLOAT DEFAULT 1.0,
  y_offset FLOAT DEFAULT 0.0,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- RLS
ALTER TABLE buddies ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Authenticated can read buddies" ON buddies
  FOR SELECT TO authenticated USING (true);

-- User buddy selection
ALTER TABLE users ADD COLUMN IF NOT EXISTS selected_buddy_id UUID REFERENCES buddies(id);

-- Auto-set default buddy for new users
CREATE OR REPLACE FUNCTION set_default_buddy_for_new_user()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE users SET selected_buddy_id = (SELECT id FROM buddies WHERE is_default LIMIT 1)
  WHERE id = NEW.id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_user_created_set_buddy
  AFTER INSERT ON users FOR EACH ROW
  EXECUTE PROCEDURE set_default_buddy_for_new_user();

-- Initial buddy (Jona)
INSERT INTO buddies (name, description, model_url, is_default, sort_order, scale)
VALUES ('Jona', 'Dein freundlicher AR-Begleiter', 'models/jona.usdz', true, 0, 0.5);
