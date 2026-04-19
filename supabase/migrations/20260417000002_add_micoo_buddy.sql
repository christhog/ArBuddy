-- Add Micoo buddy
INSERT INTO buddies (name, description, model_url, is_default, sort_order, scale, y_offset, walk_radius, walk_speed)
VALUES (
  'Micoo',
  'Ein freundlicher Begleiter mit ausdrucksstarker Mimik',
  'models/micoo.usdz',
  false,
  1,
  5.0,    -- scale: Micoo model is 10x smaller than Jona
  0.0,    -- y_offset
  1.5,    -- walk_radius
  0.3     -- walk_speed
);
