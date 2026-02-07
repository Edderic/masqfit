import Foundation

/// Protocol for handling API client events
protocol APIClientDelegate: AnyObject {
    func apiClient(_ client: APIClient, didExportMeasurementsFor user: ManagedUser)
    func apiClient(_ client: APIClient, didEncounterError error: APIError)
}

/// API client for communicating with the Rails backend
class APIClient {
    weak var delegate: APIClientDelegate?
    
    /// Base URL for the Rails backend
    private let baseURL = "https://www.breathesafe.xyz"
    
    /// URLSession for network requests
    private let urlSession: URLSession
    
    /// Authentication service for getting current user and session
    private let authService: AuthenticationService
    
    init(authService: AuthenticationService) {
        self.authService = authService
        
        // Configure URLSession with appropriate timeout and caching
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.urlSession = URLSession(configuration: config)
    }
    
    // MARK: - Facial Measurements Export
    
    /// Export facial measurements to the Rails backend for a specific user
    func exportFacialMeasurements(_ measurements: [String: Any], for userId: Int, completion: @escaping (Result<Void, APIError>) -> Void) {
        guard let url = URL(string: "\(baseURL)/users/\(userId)/facial_measurements_from_arkit") else {
            completion(.failure(.invalidURL))
            return
        }
        
        // Prepare the request payload
        let requestPayload: [String: Any] = [
            "arkit_data": measurements
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: requestPayload) else {
            completion(.failure(.invalidData))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        // Add authentication headers if available
        if let sessionToken = authService.sessionToken {
            request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }
        
        urlSession.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(.networkError(error)))
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(.invalidResponse))
                    return
                }
                
                switch httpResponse.statusCode {
                case 201:
                    // Success
                    completion(.success(()))
                case 401:
                    completion(.failure(.unauthorized))
                case 422:
                    // Parse error messages from response
                    if let data = data,
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let messages = json["messages"] as? [String] {
                        completion(.failure(.validationError(messages.joined(separator: ", "))))
                    } else {
                        completion(.failure(.validationError("Validation failed")))
                    }
                default:
                    completion(.failure(.serverError(httpResponse.statusCode)))
                }
            }
        }.resume()
    }

    func fetchAggregatedFacialMeasurements(for userId: Int, completion: @escaping (Result<[String: Double], APIError>) -> Void) {
        guard let url = URL(string: "\(baseURL)/users/\(userId)/facial_measurements") else {
            completion(.failure(.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let sessionToken = authService.sessionToken {
            request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }

        if let cookies = HTTPCookieStorage.shared.cookies(for: url) {
            let cookieHeader = HTTPCookie.requestHeaderFields(with: cookies)
            for (key, value) in cookieHeader {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        urlSession.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(.networkError(error)))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(.invalidResponse))
                    return
                }

                guard httpResponse.statusCode == 200, let data = data else {
                    completion(.failure(.serverError(httpResponse.statusCode)))
                    return
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let measurements = json["facial_measurements"] as? [[String: Any]],
                      let first = measurements.first,
                      let aggregated = first["aggregated"] as? [String: Any] else {
                    completion(.failure(.decodingError))
                    return
                }

                var result: [String: Double] = [:]
                for key in ["nose_mm", "strap_mm", "top_cheek_mm", "mid_cheek_mm", "chin_mm"] {
                    if let value = aggregated[key] as? Double {
                        result[key] = value
                    } else if let number = aggregated[key] as? NSNumber {
                        result[key] = number.doubleValue
                    }
                }

                completion(.success(result))
            }
        }.resume()
    }
    
    /// Fetch mask recommendations from the Rails backend
    func fetchMaskRecommendations(_ measurements: [String: Double], completion: @escaping (Result<[[String: Any]], APIError>) -> Void) {
        guard let url = URL(string: "\(baseURL)/mask_recommender.json") else {
            completion(.failure(.invalidURL))
            return
        }

        var payload = measurements
        if payload["facial_hair_beard_length_mm"] == nil {
            payload["facial_hair_beard_length_mm"] = 0
        }
        let requestPayload: [String: Any] = ["facial_measurements": payload]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: requestPayload) else {
            completion(.failure(.invalidData))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = jsonData

        if let sessionToken = authService.sessionToken {
            request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }

        urlSession.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(.networkError(error)))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(.invalidResponse))
                    return
                }

                guard httpResponse.statusCode == 200, let data = data else {
                    completion(.failure(.serverError(httpResponse.statusCode)))
                    return
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    completion(.failure(.decodingError))
                    return
                }

                completion(.success(json))
            }
        }.resume()
    }

    func startMaskRecommendationJob(_ measurements: [String: Double], completion: @escaping (Result<String, APIError>) -> Void) {
        guard let url = URL(string: "\(baseURL)/mask_recommender/async.json") else {
            completion(.failure(.invalidURL))
            return
        }

        var payload = measurements
        if payload["facial_hair_beard_length_mm"] == nil {
            payload["facial_hair_beard_length_mm"] = 0
        }
        let requestPayload: [String: Any] = ["facial_measurements": payload]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: requestPayload) else {
            completion(.failure(.invalidData))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = jsonData

        if let sessionToken = authService.sessionToken {
            request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }

        urlSession.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(.networkError(error)))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(.invalidResponse))
                    return
                }

                guard httpResponse.statusCode == 202, let data = data else {
                    completion(.failure(.serverError(httpResponse.statusCode)))
                    return
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let jobId = json["job_id"] as? String else {
                    completion(.failure(.decodingError))
                    return
                }

                completion(.success(jobId))
            }
        }.resume()
    }

    func fetchMaskRecommendationJobStatus(_ jobId: String, completion: @escaping (Result<[String: Any], APIError>) -> Void) {
        guard let url = URL(string: "\(baseURL)/mask_recommender/async/\(jobId).json") else {
            completion(.failure(.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let sessionToken = authService.sessionToken {
            request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }

        urlSession.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(.networkError(error)))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(.invalidResponse))
                    return
                }

                guard httpResponse.statusCode == 200, let data = data else {
                    completion(.failure(.serverError(httpResponse.statusCode)))
                    return
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(.failure(.decodingError))
                    return
                }

                completion(.success(json))
            }
        }.resume()
    }

    /// Trigger a lightweight mask recommender warmup call.
    /// Best effort: endpoint returns quickly and preloads model runtime.
    func warmupMaskRecommender(completion: @escaping (Result<Void, APIError>) -> Void) {
        guard let url = URL(string: "\(baseURL)/mask_recommender/warmup.json") else {
            completion(.failure(.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data("{}".utf8)

        if let sessionToken = authService.sessionToken {
            request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }

        urlSession.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(.networkError(error)))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(.invalidResponse))
                    return
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    completion(.failure(.serverError(httpResponse.statusCode)))
                    return
                }

                completion(.success(()))
            }
        }.resume()
    }

    /// Create a new managed user
    func createManagedUser(completion: @escaping (Result<ManagedUser, APIError>) -> Void) {
        guard let url = URL(string: "\(baseURL)/managed_users") else {
            completion(.failure(.invalidURL))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Add authentication headers if available
        if let sessionToken = authService.sessionToken {
            request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }
        
        urlSession.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(.networkError(error)))
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(.invalidResponse))
                    return
                }
                
                switch httpResponse.statusCode {
                case 201:
                    guard let data = data else {
                        completion(.failure(.invalidResponse))
                        return
                    }
                    
                    do {
                        let responseDict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                        if let managedUserDict = responseDict?["managed_user"] as? [String: Any],
                           let managedUserData = try? JSONSerialization.data(withJSONObject: managedUserDict),
                           let managedUser = try? JSONDecoder().decode(ManagedUser.self, from: managedUserData) {
                            completion(.success(managedUser))
                        } else {
                            completion(.failure(.decodingError))
                        }
                    } catch {
                        completion(.failure(.decodingError))
                    }
                case 401:
                    completion(.failure(.unauthorized))
                case 422:
                    completion(.failure(.validationError("Failed to create managed user")))
                default:
                    completion(.failure(.serverError(httpResponse.statusCode)))
                }
            }
        }.resume()
    }
    
    /// Delete a managed user
    func deleteManagedUser(userId: Int, completion: @escaping (Result<Void, APIError>) -> Void) {
        guard let url = URL(string: "\(baseURL)/managed_users/\(userId)") else {
            completion(.failure(.invalidURL))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        
        // Add authentication headers if available
        if let sessionToken = authService.sessionToken {
            request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }
        
        urlSession.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(.networkError(error)))
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(.invalidResponse))
                    return
                }
                
                switch httpResponse.statusCode {
                case 200:
                    completion(.success(()))
                case 401:
                    completion(.failure(.unauthorized))
                case 422:
                    completion(.failure(.validationError("Failed to delete managed user")))
                default:
                    completion(.failure(.serverError(httpResponse.statusCode)))
                }
            }
        }.resume()
    }
}

/// API errors
enum APIError: Error, LocalizedError {
    case invalidURL
    case invalidData
    case invalidResponse
    case networkError(Error)
    case serverError(Int)
    case unauthorized
    case validationError(String)
    case decodingError
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidData:
            return "Invalid data format"
        case .invalidResponse:
            return "Invalid response from server"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .serverError(let code):
            return "Server error: \(code)"
        case .unauthorized:
            return "Unauthorized access"
        case .validationError(let message):
            return "Validation error: \(message)"
        case .decodingError:
            return "Failed to decode response"
        }
    }
}
