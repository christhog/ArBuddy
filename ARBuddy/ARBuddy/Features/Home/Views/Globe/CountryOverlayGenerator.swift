//
//  CountryOverlayGenerator.swift
//  ARBuddy
//
//  Created by Chris Greve on 18.01.26.
//

import UIKit
import CoreGraphics
import CoreLocation

/// Generates overlay textures for highlighting countries on the globe
/// Uses equirectangular projection matching standard world map textures
enum CountryOverlayGenerator {

    // MARK: - Cached GeoJSON Data

    private static var cachedCountries: [GeoJSONCountry]?

    private static func loadCountries() -> [GeoJSONCountry] {
        if let cached = cachedCountries {
            return cached
        }
        let countries = GeoJSONParser.parseCountries()
        cachedCountries = countries
        return countries
    }

    // MARK: - Progress Colors

    /// Progress fill colors
    private enum ProgressColor {
        static let completed = UIColor(red: 0.3, green: 0.8, blue: 0.3, alpha: 0.7)    // Green: 100%
        static let inProgress = UIColor(red: 0.3, green: 0.5, blue: 0.9, alpha: 0.7)   // Blue: 50-99%
        static let started = UIColor(red: 0.9, green: 0.6, blue: 0.3, alpha: 0.7)      // Orange: 1-49%
        static let notVisited = UIColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 0.15)  // Gray: 0%
    }

    // MARK: - Texture Generation

    /// Generates an overlay texture highlighting countries based on their progress
    /// - Parameters:
    ///   - countryProgress: Array of country progress data
    ///   - size: Size of the output texture (should match earth texture size)
    /// - Returns: UIImage with highlighted countries, or nil if generation fails
    static func generateOverlayTexture(
        from countryProgress: [CountryProgress],
        size: CGSize
    ) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        guard let context = UIGraphicsGetCurrentContext() else { return nil }

        // Start with transparent background
        context.clear(CGRect(origin: .zero, size: size))

        // Load GeoJSON countries
        let geoCountries = loadCountries()

        // Create lookup for progress by ISO code
        let progressByCode = Dictionary(uniqueKeysWithValues: countryProgress.map { ($0.id, $0) })

        // Draw each country
        for geoCountry in geoCountries {
            let progress = progressByCode[geoCountry.isoCode]
            let fillColor = colorForProgress(progress)

            // Draw all polygons for this country
            for polygon in geoCountry.polygons {
                drawPolygon(polygon, in: context, size: size, fillColor: fillColor)
            }
        }

        // Draw borders on top (second pass for cleaner borders)
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.6).cgColor)
        context.setLineWidth(1.0)

        for geoCountry in geoCountries {
            for polygon in geoCountry.polygons {
                drawPolygonBorder(polygon, in: context, size: size)
            }
        }

        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return image
    }

    // MARK: - Drawing Helpers

    /// Returns fill color based on completion percentage
    private static func colorForProgress(_ progress: CountryProgress?) -> UIColor {
        guard let progress = progress, progress.totalQuestsCompleted > 0 else {
            return ProgressColor.notVisited
        }

        let percentage = progress.completionPercentage
        if percentage >= 1.0 {
            return ProgressColor.completed
        } else if percentage >= 0.5 {
            return ProgressColor.inProgress
        } else {
            return ProgressColor.started
        }
    }

    /// Converts lat/lon to texture coordinates (equirectangular projection)
    private static func texturePoint(
        lat: Double,
        lon: Double,
        size: CGSize
    ) -> CGPoint {
        // Handle date line wrapping
        var adjustedLon = lon
        if adjustedLon > 180 {
            adjustedLon -= 360
        } else if adjustedLon < -180 {
            adjustedLon += 360
        }

        let x = (adjustedLon + 180) / 360 * Double(size.width)
        let y = (90 - lat) / 180 * Double(size.height)
        return CGPoint(x: x, y: y)
    }

    /// Draws a filled polygon (with holes support)
    private static func drawPolygon(
        _ rings: [[CLLocationCoordinate2D]],
        in context: CGContext,
        size: CGSize,
        fillColor: UIColor
    ) {
        guard let outerRing = rings.first, outerRing.count >= 3 else { return }

        // Check if polygon crosses the date line (180° meridian)
        let crossesDateLine = polygonCrossesDateLine(outerRing)

        if crossesDateLine {
            // Split and draw on both sides
            drawDateLineSplitPolygon(rings, in: context, size: size, fillColor: fillColor)
        } else {
            // Normal polygon drawing
            drawSimplePolygon(rings, in: context, size: size, fillColor: fillColor)
        }
    }

    /// Draws a simple polygon that doesn't cross the date line
    private static func drawSimplePolygon(
        _ rings: [[CLLocationCoordinate2D]],
        in context: CGContext,
        size: CGSize,
        fillColor: UIColor
    ) {
        guard let outerRing = rings.first, outerRing.count >= 3 else { return }

        context.beginPath()

        // Outer ring (counter-clockwise for fill)
        let firstPoint = texturePoint(lat: outerRing[0].latitude, lon: outerRing[0].longitude, size: size)
        context.move(to: firstPoint)

        for coord in outerRing.dropFirst() {
            let point = texturePoint(lat: coord.latitude, lon: coord.longitude, size: size)
            context.addLine(to: point)
        }
        context.closePath()

        // Inner rings (holes) - clockwise
        for hole in rings.dropFirst() {
            guard hole.count >= 3 else { continue }
            let holeFirst = texturePoint(lat: hole[0].latitude, lon: hole[0].longitude, size: size)
            context.move(to: holeFirst)

            for coord in hole.dropFirst() {
                let point = texturePoint(lat: coord.latitude, lon: coord.longitude, size: size)
                context.addLine(to: point)
            }
            context.closePath()
        }

        context.setFillColor(fillColor.cgColor)
        context.fillPath(using: .evenOdd)
    }

    /// Checks if a polygon crosses the international date line
    private static func polygonCrossesDateLine(_ ring: [CLLocationCoordinate2D]) -> Bool {
        for i in 0..<ring.count {
            let current = ring[i].longitude
            let next = ring[(i + 1) % ring.count].longitude

            // Large jump indicates date line crossing
            if abs(current - next) > 180 {
                return true
            }
        }
        return false
    }

    /// Draws a polygon that crosses the date line by splitting it
    private static func drawDateLineSplitPolygon(
        _ rings: [[CLLocationCoordinate2D]],
        in context: CGContext,
        size: CGSize,
        fillColor: UIColor
    ) {
        guard let outerRing = rings.first else { return }

        // Create two versions: one shifted left, one shifted right
        let leftRing = outerRing.map { coord -> CLLocationCoordinate2D in
            var lon = coord.longitude
            if lon > 0 { lon -= 360 }
            return CLLocationCoordinate2D(latitude: coord.latitude, longitude: lon)
        }

        let rightRing = outerRing.map { coord -> CLLocationCoordinate2D in
            var lon = coord.longitude
            if lon < 0 { lon += 360 }
            return CLLocationCoordinate2D(latitude: coord.latitude, longitude: lon)
        }

        // Draw both with clipping
        context.saveGState()

        // Left side (clip to left half of texture)
        context.clip(to: CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
        drawSimplePolygon([leftRing], in: context, size: size, fillColor: fillColor)

        context.restoreGState()
        context.saveGState()

        // Right side (clip to right half of texture)
        context.clip(to: CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
        drawSimplePolygon([rightRing], in: context, size: size, fillColor: fillColor)

        context.restoreGState()
    }

    /// Draws polygon borders
    private static func drawPolygonBorder(
        _ rings: [[CLLocationCoordinate2D]],
        in context: CGContext,
        size: CGSize
    ) {
        for ring in rings {
            guard ring.count >= 3 else { continue }

            context.beginPath()

            var prevPoint = texturePoint(lat: ring[0].latitude, lon: ring[0].longitude, size: size)
            context.move(to: prevPoint)

            for coord in ring.dropFirst() {
                let point = texturePoint(lat: coord.latitude, lon: coord.longitude, size: size)

                // Skip segments that wrap around the texture (date line)
                let dx = abs(point.x - prevPoint.x)
                if dx < size.width / 2 {
                    context.addLine(to: point)
                } else {
                    context.move(to: point)
                }
                prevPoint = point
            }

            // Close path if start/end are close
            let firstPoint = texturePoint(lat: ring[0].latitude, lon: ring[0].longitude, size: size)
            let dx = abs(firstPoint.x - prevPoint.x)
            if dx < size.width / 2 {
                context.addLine(to: firstPoint)
            }

            context.strokePath()
        }
    }
}
