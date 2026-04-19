//
//  GeoJSONParser.swift
//  ARBuddy
//
//  Created by Chris Greve on 18.01.26.
//

import Foundation
import CoreLocation

/// Represents the bounding box of a country's geographic extent
struct CountryBoundingBox {
    let minLat: Double
    let maxLat: Double
    let minLon: Double
    let maxLon: Double

    var latSpan: Double { maxLat - minLat }
    var lonSpan: Double { maxLon - minLon }
    var maxSpan: Double { max(latSpan, lonSpan) }
}

/// Represents a country parsed from GeoJSON data
struct GeoJSONCountry {
    let isoCode: String                           // ISO 3166-1 alpha-2: "DE", "AT", etc.
    let name: String
    let polygons: [[[CLLocationCoordinate2D]]]    // MultiPolygon: array of polygons, each with rings
}

/// Parses GeoJSON country boundary data
enum GeoJSONParser {

    /// Parses countries from a GeoJSON file in the app bundle
    /// - Returns: Array of parsed countries, or empty array if parsing fails
    static func parseCountries() -> [GeoJSONCountry] {
        guard let url = Bundle.main.url(forResource: "countries.geo", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            print("GeoJSONParser: Could not load countries.geo.json")
            return []
        }

        return parse(from: data)
    }

    /// Parses countries from GeoJSON data
    /// - Parameter data: Raw GeoJSON data
    /// - Returns: Array of parsed countries
    static func parse(from data: Data) -> [GeoJSONCountry] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else {
            print("GeoJSONParser: Invalid GeoJSON structure")
            return []
        }

        var countries: [GeoJSONCountry] = []

        for feature in features {
            guard let properties = feature["properties"] as? [String: Any],
                  let geometry = feature["geometry"] as? [String: Any],
                  let isoCode = properties["ISO_A2"] as? String,
                  let name = properties["NAME"] as? String else {
                continue
            }

            // Skip invalid ISO codes
            guard isoCode != "-99" && isoCode.count == 2 else { continue }

            let polygons = parseGeometry(geometry)
            guard !polygons.isEmpty else { continue }

            countries.append(GeoJSONCountry(
                isoCode: isoCode,
                name: name,
                polygons: polygons
            ))
        }

        return countries
    }

    /// Parses a GeoJSON geometry object into polygon coordinates
    private static func parseGeometry(_ geometry: [String: Any]) -> [[[CLLocationCoordinate2D]]] {
        guard let type = geometry["type"] as? String,
              let coordinates = geometry["coordinates"] else {
            return []
        }

        switch type {
        case "Polygon":
            if let rings = coordinates as? [[[Double]]] {
                return [parsePolygon(rings)]
            }

        case "MultiPolygon":
            if let multiPolygon = coordinates as? [[[[Double]]]] {
                return multiPolygon.map { parsePolygon($0) }
            }

        default:
            break
        }

        return []
    }

    /// Parses a polygon's rings (outer boundary + any holes)
    private static func parsePolygon(_ rings: [[[Double]]]) -> [[CLLocationCoordinate2D]] {
        return rings.map { ring in
            ring.compactMap { coord -> CLLocationCoordinate2D? in
                guard coord.count >= 2 else { return nil }
                // GeoJSON uses [longitude, latitude] order
                return CLLocationCoordinate2D(latitude: coord[1], longitude: coord[0])
            }
        }
    }

    // MARK: - Bounding Box

    /// Calculates the bounding box for a country by its ISO code
    /// - Parameter countryCode: ISO 3166-1 alpha-2 country code (e.g., "DE", "US")
    /// - Returns: The bounding box encompassing all the country's territory, or nil if not found
    static func boundingBox(for countryCode: String) -> CountryBoundingBox? {
        let countries = parseCountries()
        guard let country = countries.first(where: { $0.isoCode == countryCode }) else {
            return nil
        }

        var minLat = Double.infinity
        var maxLat = -Double.infinity
        var minLon = Double.infinity
        var maxLon = -Double.infinity

        // Iterate through all polygons and their rings
        for polygon in country.polygons {
            for ring in polygon {
                for coord in ring {
                    minLat = min(minLat, coord.latitude)
                    maxLat = max(maxLat, coord.latitude)
                    minLon = min(minLon, coord.longitude)
                    maxLon = max(maxLon, coord.longitude)
                }
            }
        }

        // Ensure we found valid coordinates
        guard minLat != Double.infinity else { return nil }

        return CountryBoundingBox(
            minLat: minLat,
            maxLat: maxLat,
            minLon: minLon,
            maxLon: maxLon
        )
    }

    // MARK: - Point-in-Polygon Hit Testing

    /// Cached countries for hit testing
    private static var cachedCountries: [GeoJSONCountry]?

    /// Finds which country contains the given coordinate
    /// - Parameters:
    ///   - lat: Latitude of the point
    ///   - lon: Longitude of the point
    /// - Returns: ISO country code if a country is found, nil otherwise
    static func countryAt(lat: Double, lon: Double) -> String? {
        // Use cached countries for performance
        if cachedCountries == nil {
            cachedCountries = parseCountries()
        }
        guard let countries = cachedCountries else { return nil }

        let point = CLLocationCoordinate2D(latitude: lat, longitude: lon)

        for country in countries {
            for polygon in country.polygons {
                // Check the outer ring (first element) of each polygon
                if let outerRing = polygon.first, pointInPolygon(point, polygon: outerRing) {
                    return country.isoCode
                }
            }
        }
        return nil
    }

    /// Ray-casting algorithm to determine if a point is inside a polygon
    /// - Parameters:
    ///   - point: The coordinate to test
    ///   - polygon: Array of coordinates forming the polygon boundary
    /// - Returns: true if point is inside the polygon
    private static func pointInPolygon(_ point: CLLocationCoordinate2D, polygon: [CLLocationCoordinate2D]) -> Bool {
        guard polygon.count >= 3 else { return false }

        var inside = false
        var j = polygon.count - 1

        for i in 0..<polygon.count {
            let xi = polygon[i].longitude, yi = polygon[i].latitude
            let xj = polygon[j].longitude, yj = polygon[j].latitude

            if ((yi > point.latitude) != (yj > point.latitude)) &&
               (point.longitude < (xj - xi) * (point.latitude - yi) / (yj - yi) + xi) {
                inside = !inside
            }
            j = i
        }
        return inside
    }
}
