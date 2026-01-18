//
//  GeoJSONParser.swift
//  ARBuddy
//
//  Created by Chris Greve on 18.01.26.
//

import Foundation
import CoreLocation

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
}
