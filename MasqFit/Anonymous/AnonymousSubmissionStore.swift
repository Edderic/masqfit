import Foundation
import Security
import Network

struct AnonymousContribution: Codable {
    let contribution_id: UUID
    let measurement_version: Int
    let measurements: [String: Double]
    let fit_tests: [AnonymousFitTest]
    let consent_version: String
    let consent_accepted_at: String
    static let consentVersion = "anonymous-2026-09-14"
    static let consentText = "I agree to share these five facial measurements and the selected fit-test results with BreatheSafe for mask-fitting research. No name, email, face image, or landmark coordinates will be included. My saved code links contributions across visits. Submitted data is stored by BreatheSafe; offline submissions are saved on this phone and sent when connectivity is available."

    init(measurements: FacialAggregates, tests: [AnonymousFitTest]) {
        contribution_id = UUID(); measurement_version = FacialAggregates.version
        self.measurements = measurements.values; fit_tests = tests
        consent_version = Self.consentVersion
        consent_accepted_at = ISO8601DateFormatter().string(from: Date())
    }
}

enum AnonymousIdentity {
    static let prefix = "masqfit-anonymous-v1:"
    static func create() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw StoreError.message("Could not generate a participant code. Please try again.") }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    static func parse(_ text: String) -> String? {
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: prefix, with: "").lowercased()
        return code.count == 64 && code.allSatisfy { "0123456789abcdef".contains($0) } ? code : nil
    }
}

enum StoreError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

/// All mutations run on the main thread. Files contain sanitized payloads; secrets live in Keychain.
final class AnonymousSubmissionStore {
    static let shared = AnonymousSubmissionStore()
    static let changed = Notification.Name("AnonymousSubmissionStoreChanged")
    struct Item: Codable {
        let id: UUID
        var payload: AnonymousContribution?
        var state: String
        var message: String?
        var attempts: Int = 0
        var nextAttempt: Date = .distantPast
    }
    private(set) var items: [Item] = []
    private(set) var storageError: String?
    private var sending: UUID?
    private var monitor: NWPathMonitor?
    private var timer: Timer?
    private let file: URL
    private let session: URLSession
    private let credentials: AnonymousCredentialStorage

    init(directory: URL? = nil, urlSession: URLSession? = nil,
         credentialStorage: AnonymousCredentialStorage = KeychainAnonymousCredentials()) {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AnonymousContributions", isDirectory: true)
        credentials = credentialStorage
        file = directory.appendingPathComponent("queue.json")
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
        session = urlSession ?? URLSession(configuration: config)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var excluded = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            if FileManager.default.fileExists(atPath: file.path) {
                items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: file))
                for index in items.indices where items[index].state == "sending" { items[index].state = "queued" }
                // Finish credential cleanup if a previous process stopped after persisting a receipt.
                for item in items where item.state == "submitted" { credentials.remove(item.id) }
            }
        } catch { storageError = "Cannot open the protected submission queue. Reopen the app after unlocking your phone. Existing submissions have not been overwritten." }
    }
    func start() {
        guard monitor == nil else { retry(); return }
        let monitor = NWPathMonitor(); self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied { DispatchQueue.main.async { self?.retry() } }
        }
        monitor.start(queue: DispatchQueue(label: "anonymous-connectivity"))
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.retry() }
        retry()
    }
    @discardableResult func enqueue(_ payload: AnonymousContribution, credential: String) throws -> UUID {
        if let error = storageError { throw StoreError.message(error) }
        try credentials.store(credential, id: payload.contribution_id)
        items.append(Item(id: payload.contribution_id, payload: payload, state: "queued"))
        do { try persist() }
        catch { items.removeLast(); credentials.remove(payload.contribution_id); throw error }
        notify(); retry()
        return payload.contribution_id
    }
    func remove(_ id: UUID) throws {
        guard sending != id else { throw StoreError.message("Wait for this submission to finish sending.") }
        let previous = items
        items.removeAll { $0.id == id }
        do { try persist() } catch { items = previous; throw error }
        credentials.remove(id); notify()
    }
    func retry(force: Bool = false) {
        guard storageError == nil, sending == nil,
              let index = items.firstIndex(where: { $0.state == "queued" && (force || $0.nextAttempt <= Date()) }),
              let payload = items[index].payload else { return }
        let id = items[index].id
        guard let credential = credentials.read(id) else {
            items[index].state = "failed"; items[index].message = "Participant code unavailable. Remove this item and submit again using the saved code."
            saveOrReport(); return
        }
        var request = URLRequest(url: URL(string: "https://www.breathesafe.xyz/anonymous_contributions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(["contribution": payload])
        sending = id; items[index].state = "sending"
        guard saveOrReport() else { sending = nil; return }
        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self, let index = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.sending = nil
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let receipt = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                let receiptID = (receipt?["contribution_id"] as? String).flatMap(UUID.init(uuidString:))
                if error == nil && (200..<300).contains(status) && receiptID == id {
                    self.items[index].state = "submitted"; self.items[index].payload = nil
                    self.items[index].message = "Received by BreatheSafe"
                    if self.saveOrReport() { self.credentials.remove(id) }
                } else if status == 0 || status == 408 || status == 429 || status >= 500 || (200..<300).contains(status) {
                    self.items[index].state = "queued"; self.items[index].attempts += 1
                    self.items[index].message = "Waiting to retry. Your consented submission is saved on this phone."
                    self.items[index].nextAttempt = Date().addingTimeInterval(min(300, pow(2, Double(min(8, self.items[index].attempts))) * 5))
                    self.saveOrReport()
                } else {
                    self.items[index].state = "failed"
                    self.items[index].message = "Server rejected this submission (\(status)). Remove it and create a corrected submission."
                    self.saveOrReport()
                }
                self.retry()
            }
        }.resume()
    }
    private func persist() throws {
        if let error = storageError { throw StoreError.message(error) }
        try JSONEncoder().encode(items).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    @discardableResult private func saveOrReport() -> Bool {
        do { try persist(); notify(); return true }
        catch { storageError = "Could not save submission status. Reopen the app after unlocking your phone; retries use the same receipt ID."; notify(); return false }
    }
    private func notify() { NotificationCenter.default.post(name: Self.changed, object: self) }
}

protocol AnonymousCredentialStorage {
    func store(_ credential: String, id: UUID) throws
    func read(_ id: UUID) -> String?
    func remove(_ id: UUID)
}

final class KeychainAnonymousCredentials: AnonymousCredentialStorage {
    private func key(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "MasqFit.anonymous.queue.v1", kSecAttrAccount as String: id.uuidString]
    }
    func store(_ credential: String, id: UUID) throws {
        var query = key(id)
        query[kSecValueData as String] = Data(credential.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw StoreError.message("Could not securely save the participant code.") }
    }
    func read(_ id: UUID) -> String? {
        var query = key(id); query[kSecReturnData as String] = true
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    func remove(_ id: UUID) { SecItemDelete(key(id) as CFDictionary) }
}
