-- Add Aleda buddy (Genesis 9 character with full ARKit blend shape set)
INSERT INTO buddies (name, description, model_url, is_default, sort_order, scale, y_offset, walk_radius, walk_speed)
VALUES (
  'Aleda',
  'Eine freundliche Begleiterin mit realistischer Mimik',
  'models/aleda.usdz',
  false,
  2,
  0.5,    -- scale: Genesis 9 is ~1.8m, matches Jona
  0.0,    -- y_offset
  1.5,    -- walk_radius
  0.3     -- walk_speed
);
