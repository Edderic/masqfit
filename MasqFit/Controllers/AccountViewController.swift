import UIKit
import SafariServices

/// View controller for displaying account information and deletion
class AccountViewController: UIViewController {
    
    // MARK: - UI Elements
    private var scrollView: UIScrollView!
    private var contentView: UIView!
    private var emailLabel: UILabel!
    private var createdDateLabel: UILabel!
    private var formsHeaderLabel: UILabel!
    private var formsTableView: UITableView!
    private var deleteAccountButton: UIButton!
    
    // MARK: - Properties
    private let authService: AuthenticationService
    private var formsData: [(name: String, acceptedAt: String, version: String)] = []
    
    // MARK: - Initialization
    init(authService: AuthenticationService) {
        self.authService = authService
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Account"
        view.backgroundColor = UIColor(red: 47/255, green: 128/255, blue: 237/255, alpha: 1.0)
        
        setupUI()
        setupConstraints()
        loadAccountData()
    }
    
    // MARK: - Setup Methods
    private func setupUI() {
        // Create scroll view
        scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        
        // Create content view
        contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)
        
        // Email label
        emailLabel = UILabel()
        emailLabel.font = UIFont.systemFont(ofSize: 18, weight: .medium)
        emailLabel.textColor = .white
        emailLabel.numberOfLines = 0
        emailLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(emailLabel)
        
        // Created date label
        createdDateLabel = UILabel()
        createdDateLabel.font = UIFont.systemFont(ofSize: 16)
        createdDateLabel.textColor = .white
        createdDateLabel.numberOfLines = 0
        createdDateLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(createdDateLabel)
        
        // Forms header label
        formsHeaderLabel = UILabel()
        formsHeaderLabel.text = "Accepted Forms"
        formsHeaderLabel.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        formsHeaderLabel.textColor = .white
        formsHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(formsHeaderLabel)
        
        // Forms table view
        formsTableView = UITableView()
        formsTableView.backgroundColor = .white
        formsTableView.layer.cornerRadius = 8
        formsTableView.translatesAutoresizingMaskIntoConstraints = false
        formsTableView.delegate = self
        formsTableView.dataSource = self
        formsTableView.register(UITableViewCell.self, forCellReuseIdentifier: "FormCell")
        formsTableView.isScrollEnabled = false
        contentView.addSubview(formsTableView)
        
        // Delete account button
        deleteAccountButton = UIButton(type: .system)
        deleteAccountButton.setTitle("Delete Account", for: .normal)
        deleteAccountButton.backgroundColor = UIColor.systemRed
        deleteAccountButton.setTitleColor(.white, for: .normal)
        deleteAccountButton.layer.cornerRadius = 8
        deleteAccountButton.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .medium)
        deleteAccountButton.translatesAutoresizingMaskIntoConstraints = false
        deleteAccountButton.addTarget(self, action: #selector(deleteAccountButtonTapped), for: .touchUpInside)
        contentView.addSubview(deleteAccountButton)
    }
    
    private func setupConstraints() {
        NSLayoutConstraint.activate([
            // Scroll view
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            // Content view
            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            
            // Email label
            emailLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            emailLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            emailLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            
            // Created date label
            createdDateLabel.topAnchor.constraint(equalTo: emailLabel.bottomAnchor, constant: 12),
            createdDateLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            createdDateLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            
            // Forms header label
            formsHeaderLabel.topAnchor.constraint(equalTo: createdDateLabel.bottomAnchor, constant: 20),
            formsHeaderLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            formsHeaderLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            
            // Forms table view
            formsTableView.topAnchor.constraint(equalTo: formsHeaderLabel.bottomAnchor, constant: 8),
            formsTableView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            formsTableView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            formsTableView.heightAnchor.constraint(equalToConstant: 220), // Approximate height for 4 rows
            
            // Delete account button
            deleteAccountButton.topAnchor.constraint(equalTo: formsTableView.bottomAnchor, constant: 30),
            deleteAccountButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            deleteAccountButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            deleteAccountButton.heightAnchor.constraint(equalToConstant: 50),
            deleteAccountButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])
    }
    
    // MARK: - Data Loading
    private func loadAccountData() {
        guard let user = authService.currentUser else {
            emailLabel.text = "Email: Unknown"
            createdDateLabel.text = "Created: Unknown"
            return
        }
        
        // Set email
        emailLabel.text = "Email: \(user.email)"
        
        // Format and set created date
        let dateFormatter = ISO8601DateFormatter()
        if let date = dateFormatter.date(from: user.createdAt) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .long
            displayFormatter.timeStyle = .none
            createdDateLabel.text = "Account Created: \(displayFormatter.string(from: date))"
        } else {
            createdDateLabel.text = "Account Created: \(user.createdAt)"
        }
        
        // Load forms data from backend
        loadFormsData()
    }
    
    private func loadFormsData() {
        guard let url = URL(string: "https://www.breathesafe.xyz/users/get_current_user") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        // Add session cookies
        if let cookies = HTTPCookieStorage.shared.cookies(for: url) {
            let cookieHeader = HTTPCookie.requestHeaderFields(with: cookies)
            for (key, value) in cookieHeader {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                print("Error loading forms data: \(error)")
                return
            }
            
            guard let data = data else {
                print("No data received")
                return
            }
            
            // Print raw response for debugging
            if let responseString = String(data: data, encoding: .utf8) {
                print("Forms data response: \(responseString)")
            }
            
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("Failed to parse JSON")
                return
            }
            
            print("Parsed JSON: \(json)")
            
            guard let currentUser = json["currentUser"] as? [String: Any] else {
                print("No currentUser in response")
                return
            }
            
            print("Current user: \(currentUser)")
            
            guard let forms = currentUser["forms"] as? [String: Any] else {
                print("No forms field or wrong format. Forms value: \(currentUser["forms"] ?? "nil")")
                return
            }
            
            print("Forms: \(forms)")
            
            // Parse forms data
            var formsArray: [(name: String, acceptedAt: String, version: String)] = []
            
            let formNames = ["disclaimer", "consent_form", "privacy_policy", "terms_of_service"]
            let formDisplayNames = ["Disclaimer", "Consent Form", "Privacy Policy", "Terms of Service"]
            
            for (index, formName) in formNames.enumerated() {
                if let formData = forms[formName] as? [String: Any],
                   let acceptedAt = formData["accepted_at"] as? String,
                   let version = formData["version_accepted"] as? String {
                    
                    // Format the accepted_at date
                    let dateFormatter = ISO8601DateFormatter()
                    var formattedDate = acceptedAt
                    if let date = dateFormatter.date(from: acceptedAt) {
                        let displayFormatter = DateFormatter()
                        displayFormatter.dateStyle = .medium
                        displayFormatter.timeStyle = .short
                        formattedDate = displayFormatter.string(from: date)
                    }
                    
                    formsArray.append((
                        name: formDisplayNames[index],
                        acceptedAt: formattedDate,
                        version: version
                    ))
                } else {
                    print("Failed to parse form: \(formName)")
                }
            }
            
            print("Parsed \(formsArray.count) forms")
            
            DispatchQueue.main.async {
                self.formsData = formsArray
                self.formsTableView.reloadData()
                
                // Update table height based on content
                if formsArray.count > 0 {
                    let height = CGFloat(formsArray.count) * 55.0
                    self.formsTableView.constraints.forEach { constraint in
                        if constraint.firstAttribute == .height {
                            constraint.constant = height
                        }
                    }
                }
            }
        }.resume()
    }
    
    // MARK: - Actions
    @objc private func deleteAccountButtonTapped() {
        let alert = UIAlertController(
            title: "Delete Account",
            message: """
            Are you sure you want to delete your account? This will permanently delete:
            
            • Your profile and demographic information
            • All facial measurements
            • All fit test data
            • All managed users
            
            This action cannot be undone.
            """,
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Continue", style: .destructive) { [weak self] _ in
            self?.showDeleteConfirmationInput()
        })
        
        present(alert, animated: true)
    }
    
    private func showDeleteConfirmationInput() {
        let alert = UIAlertController(
            title: "Confirm Deletion",
            message: "Type DELETE to confirm account deletion:",
            preferredStyle: .alert
        )
        
        alert.addTextField { textField in
            textField.placeholder = "DELETE"
            textField.autocapitalizationType = .allCharacters
        }
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete Account", style: .destructive) { [weak self] _ in
            guard let textField = alert.textFields?.first,
                  let text = textField.text,
                  text == "DELETE" else {
                self?.showError("You must type DELETE to confirm")
                return
            }
            
            self?.deleteAccount()
        })
        
        present(alert, animated: true)
    }
    
    private func deleteAccount() {
        guard let url = URL(string: "https://www.breathesafe.xyz/users/account") else {
            showError("Invalid URL")
            return
        }
        
        // Get CSRF token first
        authService.getCSRFToken { [weak self] token in
            guard let self = self, let token = token else {
                self?.showError("Failed to get CSRF token")
                return
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(token, forHTTPHeaderField: "X-CSRF-Token")
            
            // Get session cookies
            if let cookies = HTTPCookieStorage.shared.cookies(for: url) {
                let cookieHeader = HTTPCookie.requestHeaderFields(with: cookies)
                for (key, value) in cookieHeader {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
            
            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    
                    if let error = error {
                        self.showError("Failed to delete account: \(error.localizedDescription)")
                        return
                    }
                    
                    guard let httpResponse = response as? HTTPURLResponse else {
                        self.showError("Invalid response")
                        return
                    }
                    
                    if httpResponse.statusCode == 200 {
                        // Success - show message and navigate back
                        self.showAccountDeletedMessage()
                    } else {
                        if let data = data, let responseString = String(data: data, encoding: .utf8) {
                            print("Delete failed with status \(httpResponse.statusCode): \(responseString)")
                        }
                        self.showError("Failed to delete account (Status: \(httpResponse.statusCode))")
                    }
                }
            }.resume()
        }
    }
    
    private func showAccountDeletedMessage() {
        let alert = UIAlertController(
            title: "Account Deleted",
            message: "Your account has been successfully deleted. All your data has been removed.",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            // Log out and navigate back to root
            self?.authService.logout { _ in }
            
            // Pop to root view controller (LoginViewController)
            if let navigationController = self?.navigationController {
                navigationController.popToRootViewController(animated: true)
                
                // Trigger the main menu display on LoginViewController
                if navigationController.viewControllers.first is LoginViewController {
                    // The LoginViewController's viewWillAppear will handle showing the main menu
                }
            }
        })
        
        present(alert, animated: true)
    }
    
    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - UITableViewDelegate, UITableViewDataSource
extension AccountViewController: UITableViewDelegate, UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return formsData.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "FormCell", for: indexPath)
        let form = formsData[indexPath.row]
        
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.font = UIFont.systemFont(ofSize: 14)
        cell.textLabel?.text = "\(form.name)\nAccepted: \(form.acceptedAt)\nVersion: \(form.version)"
        
        return cell
    }
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 55
    }
}
