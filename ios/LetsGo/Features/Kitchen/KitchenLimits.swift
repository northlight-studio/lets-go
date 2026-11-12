import Foundation

/// What the server accepts for a kitchen, its menu and its orders (backend/app/schemas.py),
/// so the phone stops at the same place instead of getting a validation error back.
enum OrderLimits {
    /// Most of one thing on one order.
    static let perLine = 50

    /// The orders "Your orders" still shows: a reservation until an hour after its pickup,
    /// then a picked-up one waiting for its review. Reviewed ones live only in your history.
    static func open(_ orders: [Order], now: Date) -> [Order] {
        orders.filter { o in
            switch o.status {
            case .reserved: o.pickupAt.addingTimeInterval(3600) > now
            case .pickedUp: true
            case .reviewed: false
            }
        }
    }
}

enum KitchenLimits {
    static let name = 80
    static let cuisine = 60
    static let story = 1000
    static let pickupNote = 300
    static let itemName = 80
    static let itemNote = 160

    /// Cut to what the server takes.
    static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) : text
    }
}
