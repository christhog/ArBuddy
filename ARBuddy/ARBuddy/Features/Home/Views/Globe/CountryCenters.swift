//
//  CountryCenters.swift
//  ARBuddy
//
//  Created by Chris Greve on 19.01.26.
//

import Foundation

/// Mapping of ISO country codes to their geographic center coordinates
enum CountryCenters {
    /// German display names for countries
    static let countryNames: [String: String] = [
        // Europe
        "DE": "Deutschland",
        "AT": "Österreich",
        "CH": "Schweiz",
        "FR": "Frankreich",
        "IT": "Italien",
        "ES": "Spanien",
        "PT": "Portugal",
        "GB": "Großbritannien",
        "IE": "Irland",
        "NL": "Niederlande",
        "BE": "Belgien",
        "LU": "Luxemburg",
        "PL": "Polen",
        "CZ": "Tschechien",
        "SK": "Slowakei",
        "HU": "Ungarn",
        "SI": "Slowenien",
        "HR": "Kroatien",
        "BA": "Bosnien und Herzegowina",
        "RS": "Serbien",
        "ME": "Montenegro",
        "AL": "Albanien",
        "MK": "Nordmazedonien",
        "GR": "Griechenland",
        "BG": "Bulgarien",
        "RO": "Rumänien",
        "MD": "Moldawien",
        "UA": "Ukraine",
        "BY": "Belarus",
        "LT": "Litauen",
        "LV": "Lettland",
        "EE": "Estland",
        "FI": "Finnland",
        "SE": "Schweden",
        "NO": "Norwegen",
        "DK": "Dänemark",
        "IS": "Island",
        // North America
        "US": "USA",
        "CA": "Kanada",
        "MX": "Mexiko",
        // South America
        "BR": "Brasilien",
        "AR": "Argentinien",
        "CL": "Chile",
        "CO": "Kolumbien",
        "PE": "Peru",
        "VE": "Venezuela",
        "EC": "Ecuador",
        "BO": "Bolivien",
        "PY": "Paraguay",
        "UY": "Uruguay",
        // Asia
        "CN": "China",
        "JP": "Japan",
        "KR": "Südkorea",
        "IN": "Indien",
        "TH": "Thailand",
        "VN": "Vietnam",
        "ID": "Indonesien",
        "MY": "Malaysia",
        "SG": "Singapur",
        "PH": "Philippinen",
        "TW": "Taiwan",
        "HK": "Hongkong",
        "AE": "Vereinigte Arabische Emirate",
        "SA": "Saudi-Arabien",
        "IL": "Israel",
        "TR": "Türkei",
        "RU": "Russland",
        // Oceania
        "AU": "Australien",
        "NZ": "Neuseeland",
        // Africa
        "ZA": "Südafrika",
        "EG": "Ägypten",
        "MA": "Marokko",
        "KE": "Kenia",
        "NG": "Nigeria",
        "GH": "Ghana",
        "TZ": "Tansania",
        "ET": "Äthiopien",
    ]

    /// All countries sorted by German name
    static var allCountries: [(code: String, name: String)] {
        centers.keys.sorted { code1, code2 in
            let name1 = countryNames[code1] ?? code1
            let name2 = countryNames[code2] ?? code2
            return name1.localizedCompare(name2) == .orderedAscending
        }.map { code in
            (code, countryNames[code] ?? code)
        }
    }

    /// Dictionary mapping ISO 3166-1 alpha-2 country codes to (latitude, longitude) tuples
    static let centers: [String: (lat: Double, lon: Double)] = [
        // Europe
        "DE": (51.1657, 10.4515),    // Germany
        "AT": (47.5162, 14.5501),    // Austria
        "CH": (46.8182, 8.2275),     // Switzerland
        "FR": (46.2276, 2.2137),     // France
        "IT": (41.8719, 12.5674),    // Italy
        "ES": (40.4637, -3.7492),    // Spain
        "PT": (39.3999, -8.2245),    // Portugal
        "GB": (55.3781, -3.4360),    // United Kingdom
        "IE": (53.1424, -7.6921),    // Ireland
        "NL": (52.1326, 5.2913),     // Netherlands
        "BE": (50.5039, 4.4699),     // Belgium
        "LU": (49.8153, 6.1296),     // Luxembourg
        "PL": (51.9194, 19.1451),    // Poland
        "CZ": (49.8175, 15.4730),    // Czech Republic
        "SK": (48.6690, 19.6990),    // Slovakia
        "HU": (47.1625, 19.5033),    // Hungary
        "SI": (46.1512, 14.9955),    // Slovenia
        "HR": (45.1000, 15.2000),    // Croatia
        "BA": (43.9159, 17.6791),    // Bosnia and Herzegovina
        "RS": (44.0165, 21.0059),    // Serbia
        "ME": (42.7087, 19.3744),    // Montenegro
        "AL": (41.1533, 20.1683),    // Albania
        "MK": (41.5124, 21.7453),    // North Macedonia
        "GR": (39.0742, 21.8243),    // Greece
        "BG": (42.7339, 25.4858),    // Bulgaria
        "RO": (45.9432, 24.9668),    // Romania
        "MD": (47.4116, 28.3699),    // Moldova
        "UA": (48.3794, 31.1656),    // Ukraine
        "BY": (53.7098, 27.9534),    // Belarus
        "LT": (55.1694, 23.8813),    // Lithuania
        "LV": (56.8796, 24.6032),    // Latvia
        "EE": (58.5953, 25.0136),    // Estonia
        "FI": (61.9241, 25.7482),    // Finland
        "SE": (60.1282, 18.6435),    // Sweden
        "NO": (60.4720, 8.4689),     // Norway
        "DK": (56.2639, 9.5018),     // Denmark
        "IS": (64.9631, -19.0208),   // Iceland

        // North America
        "US": (37.0902, -95.7129),   // United States
        "CA": (56.1304, -106.3468),  // Canada
        "MX": (23.6345, -102.5528),  // Mexico

        // South America
        "BR": (-14.2350, -51.9253),  // Brazil
        "AR": (-38.4161, -63.6167),  // Argentina
        "CL": (-35.6751, -71.5430),  // Chile
        "CO": (4.5709, -74.2973),    // Colombia
        "PE": (-9.1900, -75.0152),   // Peru
        "VE": (6.4238, -66.5897),    // Venezuela
        "EC": (-1.8312, -78.1834),   // Ecuador
        "BO": (-16.2902, -63.5887),  // Bolivia
        "PY": (-23.4425, -58.4438),  // Paraguay
        "UY": (-32.5228, -55.7658),  // Uruguay

        // Asia
        "CN": (35.8617, 104.1954),   // China
        "JP": (36.2048, 138.2529),   // Japan
        "KR": (35.9078, 127.7669),   // South Korea
        "IN": (20.5937, 78.9629),    // India
        "TH": (15.8700, 100.9925),   // Thailand
        "VN": (14.0583, 108.2772),   // Vietnam
        "ID": (-0.7893, 113.9213),   // Indonesia
        "MY": (4.2105, 101.9758),    // Malaysia
        "SG": (1.3521, 103.8198),    // Singapore
        "PH": (12.8797, 121.7740),   // Philippines
        "TW": (23.6978, 120.9605),   // Taiwan
        "HK": (22.3193, 114.1694),   // Hong Kong
        "AE": (23.4241, 53.8478),    // United Arab Emirates
        "SA": (23.8859, 45.0792),    // Saudi Arabia
        "IL": (31.0461, 34.8516),    // Israel
        "TR": (38.9637, 35.2433),    // Turkey
        "RU": (61.5240, 105.3188),   // Russia

        // Oceania
        "AU": (-25.2744, 133.7751),  // Australia
        "NZ": (-40.9006, 174.8860),  // New Zealand

        // Africa
        "ZA": (-30.5595, 22.9375),   // South Africa
        "EG": (26.8206, 30.8025),    // Egypt
        "MA": (31.7917, -7.0926),    // Morocco
        "KE": (-0.0236, 37.9062),    // Kenya
        "NG": (9.0820, 8.6753),      // Nigeria
        "GH": (7.9465, -1.0232),     // Ghana
        "TZ": (-6.3690, 34.8888),    // Tanzania
        "ET": (9.1450, 40.4897),     // Ethiopia
    ]

    /// Default center coordinates (Atlantic Ocean - neutral position)
    static let defaultCenter: (lat: Double, lon: Double) = (30.0, -30.0)

    /// Get center coordinates for a country code, returns default if not found
    static func center(for countryCode: String) -> (lat: Double, lon: Double) {
        centers[countryCode.uppercased()] ?? defaultCenter
    }
}
