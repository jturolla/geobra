import Foundation
import LocalAuthentication
import Observation
import Security

@MainActor @Observable
final class MapSettings {
    var source: MapSource {
        didSet {
            defaults.set(source.rawValue, forKey: "map.source")
        }
    }
    var isBasemapVisible: Bool {
        didSet { defaults.set(isBasemapVisible, forKey: "map.basemapVisible") }
    }
    var showsGrid: Bool {
        didSet { defaults.set(showsGrid, forKey: "map.showsGrid") }
    }
    private(set) var credentialRevision = 0
    private(set) var hasGoogleKey = false
    private(set) var credentialError: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        source = defaults.string(forKey: "map.source").flatMap(MapSource.init(rawValue:)) ?? .openStreetMap
        isBasemapVisible = defaults.object(forKey: "map.basemapVisible") as? Bool ?? true
        showsGrid = defaults.bool(forKey: "map.showsGrid")
        readCredentialAvailability()
    }

    var needsGoogleKey: Bool { source.requiresAPIKey && !hasGoogleKey }

    var configuration: MapConfiguration {
        MapConfiguration(
            source: source,
            isBasemapVisible: isBasemapVisible,
            showsGrid: showsGrid,
            credentialRevision: credentialRevision
        )
    }

    func reloadCredentials() {
        readCredentialAvailability()
        credentialRevision += 1
    }

    func reloadMap() {
        credentialRevision += 1
    }

    private func readCredentialAvailability() {
        do {
            hasGoogleKey = try GoogleMapsCredentialStore.read() != nil
            credentialError = nil
        } catch {
            hasGoogleKey = false
            credentialError = error.localizedDescription
        }
    }
}

enum GoogleMapsCredentialStore {
    private static let service = "com.geobra.mac.google-maps"
    private static let account = "maps-tile-api-key"

    static func read() throws -> String? {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw CredentialError.invalidSavedKey
        }
        return key
    }

    static func save(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { throw CredentialError.invalidKey }
        let data = Data(key.utf8)
        let values = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(itemQuery as CFDictionary, values as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw CredentialError.keychain(updateStatus) }
        var item = itemQuery
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Geobra Google Maps API Key"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CredentialError.keychain(addStatus) }
    }

    static func delete() throws {
        let status = SecItemDelete(itemQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.keychain(status) }
    }

    private static var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private enum CredentialError: LocalizedError {
        case invalidKey
        case invalidSavedKey
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidKey:
                return "Enter a Google Maps API key without spaces."
            case .invalidSavedKey:
                return "The saved Google Maps key is invalid. Enter the key again in Settings."
            case .keychain(let status):
                return "Geobra could not access its Google Maps key in Keychain. Keychain returned error \(status)."
            }
        }
    }
}
