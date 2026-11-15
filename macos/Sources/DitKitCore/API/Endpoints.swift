import Foundation

public enum Endpoints {
    public static let health = "/api/v1/health"
    public static let disks = "/api/v1/disks"
    public static let shutdown = "/api/v1/shutdown"

    public static func smart(device: String) -> String {
        let encoded = device.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? device
        return "/api/v1/smart?device=\(encoded)"
    }
}
