-- Add spatial search function for POIs within a radius
-- Uses Haversine formula to calculate distance between points

CREATE OR REPLACE FUNCTION pois_within_radius(lat float, lon float, radius_meters float)
RETURNS SETOF pois AS $$
  SELECT *
  FROM pois
  WHERE (
    6371000 * acos(
      LEAST(1.0, GREATEST(-1.0,
        cos(radians(lat)) * cos(radians(latitude)) *
        cos(radians(longitude) - radians(lon)) +
        sin(radians(lat)) * sin(radians(latitude))
      ))
    )
  ) <= radius_meters
$$ LANGUAGE sql STABLE;

-- Add comment explaining the function
COMMENT ON FUNCTION pois_within_radius(float, float, float) IS
'Returns all POIs within the specified radius (in meters) from the given latitude/longitude.
Uses the Haversine formula for spherical distance calculation.
Parameters:
  - lat: center latitude
  - lon: center longitude
  - radius_meters: search radius in meters';
