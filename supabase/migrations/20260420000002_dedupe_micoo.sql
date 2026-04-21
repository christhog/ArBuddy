-- Remove duplicate Micoo buddy rows created by re-running the Micoo insert.
-- Keeps the oldest (earliest created_at) Micoo row and re-points any users
-- referencing the duplicates to the survivor before deleting them.

DO $$
DECLARE
  keeper_id UUID;
BEGIN
  SELECT id INTO keeper_id
  FROM buddies
  WHERE name = 'Micoo'
  ORDER BY created_at ASC, id ASC
  LIMIT 1;

  IF keeper_id IS NULL THEN
    RETURN;
  END IF;

  UPDATE users
  SET selected_buddy_id = keeper_id
  WHERE selected_buddy_id IN (
    SELECT id FROM buddies WHERE name = 'Micoo' AND id <> keeper_id
  );

  DELETE FROM buddies
  WHERE name = 'Micoo' AND id <> keeper_id;
END $$;
