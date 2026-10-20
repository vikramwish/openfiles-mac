import Foundation
import ImageIO

/// Derived, local-only metadata. Coordinates come from the image, never from a guessed scene.
public struct PhotoLocation: Codable, Hashable, Sendable {
    public let latitude: Double?
    public let longitude: Double?
    public let names: [String]

    static func read(_ source: CGImageSource) -> PhotoLocation? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        func coordinate(_ value: CFString, _ ref: CFString, negative: String, bound: Double) -> Double? {
            guard let number = gps[value as String] as? NSNumber else { return nil }
            let magnitude = number.doubleValue
            guard magnitude.isFinite, magnitude >= 0, magnitude <= bound,
                  let direction = (gps[ref as String] as? String)?.uppercased(),
                  [negative, negative == "S" ? "N" : "E"].contains(direction) else { return nil }
            return direction == negative ? -magnitude : magnitude
        }
        let lat = coordinate(kCGImagePropertyGPSLatitude, kCGImagePropertyGPSLatitudeRef, negative: "S", bound: 90)
        let lon = coordinate(kCGImagePropertyGPSLongitude, kCGImagePropertyGPSLongitudeRef, negative: "W", bound: 180)
        let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
        let keys = [kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState, kCGImagePropertyIPTCCountryPrimaryLocationName]
        let names = keys.compactMap { iptc[$0 as String] as? String }.map { String($0.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard (lat != nil && lon != nil) || !names.isEmpty else { return nil }
        return PhotoLocation(latitude: lat != nil && lon != nil ? lat : nil, longitude: lat != nil && lon != nil ? lon : nil, names: names)
    }

    static func normalized(_ name: String) -> String {
        FileSearchQuery.words(name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))).joined(separator: " ")
    }

    var searchKeys: Set<String> {
        Set(names.map(Self.normalized)).union(Self.cities.keys.filter { matches($0) })
    }

    public func matches(_ place: String) -> Bool {
        let key = Self.normalized(place)
        guard !key.isEmpty else { return false }
        if names.contains(where: { Self.normalized($0) == key }) { return true }
        guard let latitude, let longitude, let city = Self.cities[key] else { return false }
        // Haversine distance, including antimeridian crossings. City radius is approximate.
        let radians = Double.pi / 180
        let a = pow(sin((city.lat - latitude) * radians / 2), 2)
            + cos(latitude * radians) * cos(city.lat * radians) * pow(sin((city.lon - longitude) * radians / 2), 2)
        let distance = 6371 * 2 * asin(sqrt(min(1, max(0, a))))
        return distance <= city.radius
    }

    // A deliberately bounded offline lookup; embedded IPTC names support other places.
    // These are search radii around city centres, not administrative boundaries.
    private static let cities: [String: (lat: Double, lon: Double, radius: Double)] = [
        "sydney": (-33.8688, 151.2093, 50), "melbourne": (-37.8136, 144.9631, 50),
        "brisbane": (-27.4698, 153.0251, 40), "perth": (-31.9523, 115.8613, 50),
        "adelaide": (-34.9285, 138.6007, 35), "canberra": (-35.2809, 149.1300, 30),
        "hobart": (-42.8821, 147.3272, 25), "darwin": (-12.4634, 130.8456, 30),
        "gold coast": (-28.0167, 153.4000, 35), "newcastle": (-32.9283, 151.7817, 30),
        "auckland": (-36.8485, 174.7633, 40), "wellington": (-41.2866, 174.7756, 25),
        "london": (51.5074, -0.1278, 40), "paris": (48.8566, 2.3522, 30),
        "new york": (40.7128, -74.0060, 40), "san francisco": (37.7749, -122.4194, 20),
        "los angeles": (34.0522, -118.2437, 50), "tokyo": (35.6762, 139.6503, 40),
        "singapore": (1.3521, 103.8198, 25)
    ]
}
