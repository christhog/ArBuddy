-- Update user_country_statistics to show ALL countries with POIs
-- Even countries where the user has no progress (shows 0/XX)

DROP VIEW IF EXISTS user_country_statistics;

CREATE OR REPLACE VIEW user_country_statistics AS
WITH country_totals AS (
  -- All countries that have at least one POI
  SELECT
    country,
    COUNT(*)::integer as total_pois_in_country
  FROM pois
  WHERE country IS NOT NULL
  GROUP BY country
),
user_progress AS (
  -- User's progress per country (only countries with progress)
  SELECT
    upp.user_id,
    p.country,
    COUNT(DISTINCT p.id)::integer as completed_pois,
    SUM(CASE WHEN upp.visit_completed THEN 1 ELSE 0 END)::integer as visits_completed,
    SUM(CASE WHEN upp.photo_completed THEN 1 ELSE 0 END)::integer as photos_completed,
    SUM(CASE WHEN upp.ar_completed THEN 1 ELSE 0 END)::integer as ar_completed,
    SUM(CASE WHEN upp.quiz_completed THEN 1 ELSE 0 END)::integer as quizzes_completed
  FROM user_poi_progress upp
  JOIN pois p ON p.id = upp.poi_id
  WHERE p.country IS NOT NULL
  GROUP BY upp.user_id, p.country
)
SELECT
  auth.uid() as user_id,
  ct.country,
  COALESCE(up.completed_pois, 0) as completed_pois,
  COALESCE(up.visits_completed, 0) as visits_completed,
  COALESCE(up.photos_completed, 0) as photos_completed,
  COALESCE(up.ar_completed, 0) as ar_completed,
  COALESCE(up.quizzes_completed, 0) as quizzes_completed,
  ct.total_pois_in_country
FROM country_totals ct
LEFT JOIN user_progress up ON up.country = ct.country AND up.user_id = auth.uid();

GRANT SELECT ON user_country_statistics TO authenticated;
