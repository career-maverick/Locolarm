import CoreLocation
import Foundation

/// Represents an alarm destination with coordinate and trigger radius metadata.
struct Destination: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    var radiusMeters: Double
    var createdAt: Date

    /// Creates a destination value that can be saved and tracked.
    init(
        id: UUID = UUID(),
        name: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: Double,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.createdAt = createdAt
    }

    /// Convenience coordinate used by map and location APIs.
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// User-defined quick place that wraps a destination with a short label.
struct CustomPlace: Codable, Equatable, Identifiable {
    let id: UUID
    var label: String
    var destination: Destination
    var lastUsedAt: Date?

    /// Creates a custom place and enforces the 10-character label limit.
    init(
        id: UUID = UUID(),
        label: String,
        destination: Destination,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.label = String(label.prefix(10))
        self.destination = destination
        self.lastUsedAt = lastUsedAt
    }
}

extension Destination {
    /// Placeholder/default Home slot used before user configures a real location.
    static let savedHome = Destination(
        id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA") ?? UUID(),
        name: "Home",
        latitude: 0,
        longitude: 0,
        radiusMeters: 200
    )

    /// Placeholder/default Work slot used before user configures a real location.
    static let savedWork = Destination(
        id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB") ?? UUID(),
        name: "Work",
        latitude: 0,
        longitude: 0,
        radiusMeters: 200
    )
}
