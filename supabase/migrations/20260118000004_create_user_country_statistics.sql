-- Migration: Create user_country_statistics view
-- This view aggregates user progress by country for the country progress feature
-- It counts quests completed per country and total POIs in each country

CREATE OR REPLACE VIEW user_country_statistics AS
SELECT
  upp.user_id,
  p.country,
  COUNT(DISTINCT p.id) as completed_pois,
  SUM(CASE WHEN upp.visit_completed THEN 1 ELSE 0 END)::integer as visits_completed,
  SUM(CASE WHEN upp.photo_completed THEN 1 ELSE 0 END)::integer as photos_completed,
  SUM(CASE WHEN upp.ar_completed THEN 1 ELSE 0 END)::integer as ar_completed,
  SUM(CASE WHEN upp.quiz_completed THEN 1 ELSE 0 END)::integer as quizzes_completed,
  (SELECT COUNT(*) FROM pois WHERE pois.country = p.country)::integer as total_pois_in_country
FROM user_poi_progress upp
JOIN pois p ON p.id = upp.poi_id
WHERE p.country IS NOT NULL
GROUP BY upp.user_id, p.country;

-- Grant access to the view for authenticated users
GRANT SELECT ON user_country_statistics TO authenticated;
