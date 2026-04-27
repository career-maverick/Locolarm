import CoreLocation
import Foundation

struct Destination: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    var radiusMeters: Double
    var createdAt: Date

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

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct CustomPlace: Codable, Equatable, Identifiable {
    let id: UUID
    var label: String
    var destination: Destination
    var lastUsedAt: Date?

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
    static let savedHome = Destination(
        id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA") ?? UUID(),
        name: "Home",
        latitude: 0,
        longitude: 0,
        radiusMeters: 200
    )

    static let savedWork = Destination(
        id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB") ?? UUID(),
        name: "Work",
        latitude: 0,
        longitude: 0,
        radiusMeters: 200
    )
}
