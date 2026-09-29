import Foundation
import Security

/// Protocol for handling authentication events
protocol AuthenticationServiceDelegate: AnyObject {
    func authenticationService(_ service: AuthenticationService, didLogin user: User)
    func authenticationService(_ service: AuthenticationService, didLogout user: User?)
    func authenticationService(_ service: AuthenticationService, didEncounterError error: AuthenticationError)
    func authenticationService(_ service: AuthenticationService, didLoadManagedUsers users: [ManagedUser])
}

/// Service responsible for handling authentication with the Rails backend
class AuthenticationService {
    weak var delegate: AuthenticationServiceDelegate?
    
    /// Base URL for the Rails backend
    private let baseURL = "https://www.breathesafe.xyz"
    
    /// Current authenticated user
    private(set) var currentUser: User?
    
    /// Current user's email
    var currentUserEmail: String? {
        return currentUser?.email
    }
    
    /// Current session token (if using token-based auth)
    private(set) var sessionToken: String?
    
    /// URLSession for network requests
    private let urlSession: URLSession
    
    /// Cookie storage for maintaining session
    private let cookieStorage = HTTPCookieStorage.shared
    
    init() {
        // Configure URLSession with appropriate timeout and caching
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpCookieStorage = cookieStorage
        config.httpCookieAcceptPolicy = .always
        self.urlSession = URLSession(configuration: config)
        
        // Try to restore session from keychain
        restoreSession()
    }
    
    // MARK: - Authentication Methods
    
    /// Login with email and password
    func login(email: String, password: String, completion: @escaping (Result<User, AuthenticationError>) -> Void) {
        // First, get CSRF token (this will create a new session)
        getCSRFToken { [weak self] csrfToken in
            guard let self = self else { return }
            
            // Use the custom route from Rails routes that points to users/sessions#create
            let loginURL = "\(self.baseURL)/users/log_in"
            
            // Use form-encoded data for Devise compatibility
            var parameters = [
                "user[email]": email,
                "user[password]": password
            ]
            
            // Add CSRF token if available
            if let token = csrfToken {
                parameters["authenticity_token"] = token
            }
            
            guard let url = URL(string: loginURL),
                  let formData = self.createFormData(from: parameters) else {
                completion(.failure(.invalidRequest))
                return
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            
            // Add CSRF token as header (in addition to form parameter for compatibility)
            if let token = csrfToken {
                request.setValue(token, forHTTPHeaderField: "X-CSRF-Token")
            }
            
            request.httpBody = formData
            
            print("Login request URL: \(url)")
            print("Login request method: \(request.httpMethod ?? "unknown")")
            print("Login request headers: \(request.allHTTPHeaderFields ?? [:])")
            if let bodyString = String(data: formData, encoding: .utf8) {
                print("Login request body: \(bodyString)")
            }
            
            self.urlSession.dataTask(with: request) { [weak self] data, response, error in
                DispatchQueue.main.async {
                    if let error = error {
                        print("Network error: \(error)")
                        completion(.failure(.networkError(error)))
                        return
                    }
                    
                    guard let httpResponse = response as? HTTPURLResponse else {
                        print("Invalid response")
                        completion(.failure(.invalidResponse))
                        return
                    }
                    
                    print("Response status: \(httpResponse.statusCode)")
                    if let data = data, let responseString = String(data: data, encoding: .utf8) {
                        print("Response body: \(responseString)")
                    }
                    
                    // Handle different response codes
                    switch httpResponse.statusCode {
                    case 200, 201:
                        // Success - Rails returned HTML page, which means login was successful
                        print("Login request successful, now getting current user info")
                        
                        // Debug: Print cookies after successful login
                        if let url = URL(string: self?.baseURL ?? ""),
                           let cookies = self?.cookieStorage.cookies(for: url) {
                            print("Cookies after successful login:")
                            for cookie in cookies {
                                print("  - \(cookie.name): \(cookie.value)")
                            }
                        }
                        
                        // Now get the current user info
                        self?.getCurrentUser { result in
                            switch result {
                            case .success(let user):
                                print("Got current user: \(user.email) with ID: \(user.id)")
                                self?.currentUser = user
                                self?.saveCredentials(email: email, password: password)
                                self?.delegate?.authenticationService(self!, didLogin: user)
                                completion(.success(user))
                            case .failure(let error):
                                // If we can't get current user, still consider login successful
                                // since we got a 200 response
                                print("Login successful but couldn't get user info: \(error)")
                                let dummyUser = User(id: 0, email: email, createdAt: "", updatedAt: "")
                                self?.currentUser = dummyUser
                                self?.saveCredentials(email: email, password: password)
                                self?.delegate?.authenticationService(self!, didLogin: dummyUser)
                                completion(.success(dummyUser))
                            }
                        }
                    case 401:
                        completion(.failure(.invalidCredentials))
                    case 422:
                        completion(.failure(.validationError))
                    default:
                        completion(.failure(.serverError(httpResponse.statusCode)))
                    }
                }
            }.resume()
        }
    }
    
    /// Clear local authentication state without making a network call
    func invalidateLocalSession() {
        let user = currentUser
        currentUser = nil
        sessionToken = nil
        clearCredentials()
        clearCookies()
        delegate?.authenticationService(self, didLogout: user)
    }

    /// Logout current user
    func logout(completion: @escaping (Result<Void, AuthenticationError>) -> Void) {
        guard let url = URL(string: "\(baseURL)/users/log_out") else {
            completion(.failure(.invalidRequest))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        
        // Add session cookie if available
        if let sessionToken = sessionToken {
            request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }
        
        urlSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(.networkError(error)))
                    return
                }
                
                let user = self?.currentUser
                self?.currentUser = nil
                self?.sessionToken = nil
                self?.clearCredentials()
                self?.clearCookies()
                
                self?.delegate?.authenticationService(self!, didLogout: user)
                completion(.success(()))
            }
        }.resume()
    }
    
    /// Get current user information
    func getCurrentUser(completion: @escaping (Result<User, AuthenticationError>) -> Void) {
        guard let url = URL(string: "\(baseURL)/users/get_current_user") else {
            completion(.failure(.invalidRequest))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        urlSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("getCurrentUser network error: \(error)")
                    completion(.failure(.networkError(error)))
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    print("getCurrentUser invalid response")
                    completion(.failure(.invalidResponse))
                    return
                }
                
                print("getCurrentUser response status: \(httpResponse.statusCode)")
                if let data = data, let responseString = String(data: data, encoding: .utf8) {
                    print("getCurrentUser response body: \(responseString)")
                }
                
                switch httpResponse.statusCode {
                case 200:
                    guard let data = data else {
                        completion(.failure(.invalidResponse))
                        return
                    }
                    
                    do {
                        let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
                        if let user = authResponse.currentUser {
                            self?.currentUser = user
                            completion(.success(user))
                        } else {
                            completion(.failure(.notAuthenticated))
                        }
                    } catch {
                        print("getCurrentUser decoding error: \(error)")
                        completion(.failure(.decodingError(error)))
                    }
                case 401:
                    completion(.failure(.notAuthenticated))
                default:
                    completion(.failure(.serverError(httpResponse.statusCode)))
                }
            }
        }.resume()
    }
    
    /// Load managed users for the current user
    func loadManagedUsers(completion: @escaping (Result<[ManagedUser], AuthenticationError>) -> Void) {
        guard let url = URL(string: "\(baseURL)/managed_users") else {
            completion(.failure(.invalidRequest))
            return
        }
        
        // Debug: Print current cookies
        if let cookies = cookieStorage.cookies(for: url) {
            print("Cookies being sent with managed_users request:")
            for cookie in cookies {
                print("  - \(cookie.name): \(cookie.value)")
            }
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        urlSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("loadManagedUsers network error: \(error)")
                    completion(.failure(.networkError(error)))
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    print("loadManagedUsers invalid response")
                    completion(.failure(.invalidResponse))
                    return
                }
                
                print("loadManagedUsers response status: \(httpResponse.statusCode)")
                if let data = data, let responseString = String(data: data, encoding: .utf8) {
                    print("loadManagedUsers response body: \(responseString)")
                }
                
                switch httpResponse.statusCode {
                case 200:
                    guard let data = data else {
                        completion(.failure(.invalidResponse))
                        return
                    }
                    
                    do {
                        let managedUsersResponse = try JSONDecoder().decode(ManagedUsersResponse.self, from: data)
                        self?.delegate?.authenticationService(self!, didLoadManagedUsers: managedUsersResponse.managedUsers)
                        completion(.success(managedUsersResponse.managedUsers))
                    } catch {
                        print("loadManagedUsers decoding error: \(error)")
                        completion(.failure(.decodingError(error)))
                    }
                case 401:
                    completion(.failure(.notAuthenticated))
                case 422:
                    completion(.failure(.validationError))
                default:
                    completion(.failure(.serverError(httpResponse.statusCode)))
                }
            }
        }.resume()
    }
    
    /// Check if user is currently authenticated
    var isAuthenticated: Bool {
        return currentUser != nil
    }
    
    // MARK: - Credential Management
    
    /// Save credentials securely to Keychain
    private func saveCredentials(email: String, password: String) {
        let emailData = email.data(using: .utf8)!
        let passwordData = password.data(using: .utf8)!
        
        // Save email
        let emailQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "breathesafe_email",
            kSecValueData as String: emailData
        ]
        
        // Delete existing email
        SecItemDelete(emailQuery as CFDictionary)
        
        // Add new email
        SecItemAdd(emailQuery as CFDictionary, nil)
        
        // Save password
        let passwordQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "breathesafe_password",
            kSecValueData as String: passwordData
        ]
        
        // Delete existing password
        SecItemDelete(passwordQuery as CFDictionary)
        
        // Add new password
        SecItemAdd(passwordQuery as CFDictionary, nil)
    }
    
    /// Restore session from saved credentials
    private func restoreSession() {
        // Try to get saved credentials
        guard let email = getSavedEmail(),
              let password = getSavedPassword() else {
            return
        }
        
        // Attempt to login with saved credentials
        login(email: email, password: password) { [weak self] result in
            switch result {
            case .success(let user):
                print("Successfully restored session for user: \(user.email)")
            case .failure(let error):
                print("Failed to restore session: \(error)")
                // Clear invalid credentials
                self?.clearCredentials()
            }
        }
    }
    
    /// Get saved email from Keychain
    private func getSavedEmail() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "breathesafe_email",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let email = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return email
    }
    
    /// Get saved password from Keychain
    private func getSavedPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "breathesafe_password",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return password
    }
    
    /// Clear saved credentials from Keychain
    private func clearCredentials() {
        let emailQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "breathesafe_email"
        ]
        
        let passwordQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "breathesafe_password"
        ]
        
        SecItemDelete(emailQuery as CFDictionary)
        SecItemDelete(passwordQuery as CFDictionary)
    }
    
    /// Clear all cookies for the backend domain
    private func clearCookies() {
        guard let url = URL(string: baseURL) else { return }
        
        if let cookies = cookieStorage.cookies(for: url) {
            for cookie in cookies {
                print("Deleting cookie: \(cookie.name)")
                cookieStorage.deleteCookie(cookie)
            }
        }
        
        // Also clear all cookies just to be safe
        if let allCookies = cookieStorage.cookies {
            for cookie in allCookies {
                if cookie.domain.contains("breathesafe.xyz") {
                    print("Deleting breathesafe cookie: \(cookie.name) for domain: \(cookie.domain)")
                    cookieStorage.deleteCookie(cookie)
                }
            }
        }
    }
    
    /// Create form-encoded data from parameters
    private func createFormData(from parameters: [String: String]) -> Data? {
        // Create a custom character set that properly encodes form data
        // We need to encode special characters including +, &, =, etc.
        var allowedCharacters = CharacterSet.alphanumerics
        allowedCharacters.insert(charactersIn: "-._~") // RFC 3986 unreserved characters
        
        let formItems = parameters.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? ""
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? ""
            return "\(encodedKey)=\(encodedValue)"
        }
        let formString = formItems.joined(separator: "&")
        return formString.data(using: .utf8)
    }
    
    /// Get CSRF token from Rails backend
    func getCSRFToken(completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "\(baseURL)/csrf_token") else {
            completion(nil)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        urlSession.dataTask(with: request) { data, response, error in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let token = json["csrf_token"] as? String {
                completion(token)
            } else {
                completion(nil)
            }
        }.resume()
    }
}

/// Authentication errors
enum AuthenticationError: Error, LocalizedError {
    case invalidCredentials
    case notAuthenticated
    case invalidRequest
    case invalidResponse
    case networkError(Error)
    case serverError(Int)
    case validationError
    case decodingError(Error)
    
    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Invalid email or password"
        case .notAuthenticated:
            return "User is not authenticated"
        case .invalidRequest:
            return "Invalid request"
        case .invalidResponse:
            return "Invalid response from server"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .serverError(let code):
            return "Server error: \(code)"
        case .validationError:
            return "Validation error"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        }
    }
}