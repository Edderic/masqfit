import UIKit
import ARKit
import SceneKit
import SafariServices

@available(iOS 13.0, *)
class FaceMeasurementViewController: UIViewController {
    enum MeasurementMode {
        case contribute
        case recommend
    }

    // MARK: - UI Elements
    var sceneView: ARSCNView!
    var instructionLabel: UILabel!
    var measurementLabel: UITextView!
    var startButton: UIButton!
    var exportButton: UIButton!
    var cancelButton: UIButton!
    var statusLabel: UILabel!
    var progressView: UIProgressView!
    var logoutButton: UIButton!
    var toggleMeasurementsButton: UIButton!
    private var loadingOverlay: UIView!
    private var loadingIndicator: UIActivityIndicatorView!

    // MARK: - Properties
    private let measurementEngine = MeasurementEngine()
    private let dataExportManager = DataExportManager()
    private var isMeasuring = false
    private var measurementCount = 0
    private let requiredMeasurements = 30 // Number of measurements to collect
    private var isMeasurementsVisible = false
    private var shouldRecommendWhenMeasurementCompletes = false
    private var startButtonHeightConstraint: NSLayoutConstraint?
    private var exportButtonHeightConstraint: NSLayoutConstraint?
    private var managedUsers: [ManagedUser] = []

    // Authentication and API properties
    // TODO: Uncomment these once the new model files are added to the Xcode project
    var selectedUser: ManagedUser?
    var authService: AuthenticationService?
    var apiClient: APIClient?
    var offlineSyncManager: OfflineSyncManager?
    var measurementMode: MeasurementMode = .contribute
    var onRecommend: (([String: Double]) -> Void)?

    // MARK: - Overlay Properties
    private var landmarkNodes: [Int: SCNNode] = [:]
    private var measurementLineNodes: [String: SCNNode] = [:]

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupARKit()
        setupDelegates()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startARSession()
        loadManagedUsers()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sceneView.session.pause()
    }

    // MARK: - Setup Methods
    private func setupUI() {
        // Update title to show selected user
        if let user = selectedUser {
            title = "Face Measurement - \(user.displayName)"
        } else {
            title = "Face Measurement"
        }
        view.backgroundColor = UIColor.systemBackground
        
        // Set navigation bar title text color to white
        navigationController?.navigationBar.titleTextAttributes = [.foregroundColor: UIColor.white]
        navigationController?.navigationBar.largeTitleTextAttributes = [.foregroundColor: UIColor.white]

        // Create ARSCNView
        sceneView = ARSCNView()
        sceneView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sceneView)

        // Create instruction label
        instructionLabel = UILabel()
        instructionLabel.text = "Position your face close to the camera (less than 12 inches away) in portrait mode. Remove glasses, hats, or anything covering your face."
        instructionLabel.numberOfLines = 0
        instructionLabel.textAlignment = .center
        instructionLabel.font = UIFont.systemFont(ofSize: 16)
        instructionLabel.textColor = UIColor.label
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(instructionLabel)

        // Create progress view
        progressView = UIProgressView(progressViewStyle: .default)
        progressView.progress = 0.0
        progressView.isHidden = true
        progressView.progressTintColor = UIColor.systemBlue
        progressView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressView)

        // Create status label
        statusLabel = UILabel()
        statusLabel.text = "Ready to start"
        statusLabel.textAlignment = .center
        statusLabel.font = UIFont.systemFont(ofSize: 14)
        statusLabel.textColor = UIColor.secondaryLabel
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        // Create measurement label (using UITextView for better text display)
        measurementLabel = UITextView()
        measurementLabel.text = measurementMode == .recommend
            ? "Measurements will appear here after recommendation starts measurement collection.\n\nPress 'Recommend' to begin."
            : "Measurements will appear here after you start a measurement.\n\nPress 'Start Measurement' to begin collecting facial measurement data."
        measurementLabel.font = UIFont.systemFont(ofSize: 14)
        measurementLabel.backgroundColor = UIColor.secondarySystemBackground
        measurementLabel.textColor = UIColor.label
        measurementLabel.isEditable = false
        measurementLabel.isScrollEnabled = true
        measurementLabel.layer.cornerRadius = 8
        measurementLabel.layer.borderWidth = 1
        measurementLabel.layer.borderColor = UIColor.separator.cgColor
        measurementLabel.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        measurementLabel.isHidden = true
        measurementLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(measurementLabel)

        // Create start button
        startButton = UIButton(type: .system)
        startButton.setTitle("Start Measurement", for: .normal)
        startButton.backgroundColor = UIColor.systemBlue
        startButton.setTitleColor(UIColor.white, for: .normal)
        startButton.layer.cornerRadius = 8
        startButton.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .medium)
        startButton.translatesAutoresizingMaskIntoConstraints = false
        startButton.addTarget(self, action: #selector(startButtonTapped(_:)), for: .touchUpInside)
        view.addSubview(startButton)

        // Create save button (formerly export button)
        exportButton = UIButton(type: .system)
        let exportTitle = measurementMode == .recommend ? "Recommend" : "Save"
        exportButton.setTitle(exportTitle, for: .normal)
        exportButton.backgroundColor = UIColor.systemGreen
        exportButton.setTitleColor(UIColor.white, for: .normal)
        exportButton.layer.cornerRadius = 8
        exportButton.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .medium)
        exportButton.isEnabled = measurementMode == .recommend
        exportButton.isHidden = measurementMode != .recommend
        exportButton.translatesAutoresizingMaskIntoConstraints = false
        exportButton.addTarget(self, action: #selector(saveButtonTapped(_:)), for: .touchUpInside)
        view.addSubview(exportButton)

        // Create cancel button
        cancelButton = UIButton(type: .system)
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.backgroundColor = UIColor.systemRed
        cancelButton.setTitleColor(UIColor.white, for: .normal)
        cancelButton.layer.cornerRadius = 8
        cancelButton.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .medium)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.addTarget(self, action: #selector(cancelButtonTapped(_:)), for: .touchUpInside)
        view.addSubview(cancelButton)

        // Create logout button (hidden, accessed via Other Options)
        logoutButton = UIButton(type: .system)
        logoutButton.setTitle("Logout", for: .normal)
        logoutButton.backgroundColor = UIColor.systemRed
        logoutButton.setTitleColor(UIColor.white, for: .normal)
        logoutButton.layer.cornerRadius = 8
        logoutButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        logoutButton.isHidden = true
        logoutButton.translatesAutoresizingMaskIntoConstraints = false
        logoutButton.addTarget(self, action: #selector(logoutButtonTapped(_:)), for: .touchUpInside)
        view.addSubview(logoutButton)

        // Create toggle measurements button (hidden, accessed via Other Options)
        toggleMeasurementsButton = UIButton(type: .system)
        toggleMeasurementsButton.setTitle("Show Measurements", for: .normal)
        toggleMeasurementsButton.backgroundColor = UIColor.systemGray
        toggleMeasurementsButton.setTitleColor(UIColor.white, for: .normal)
        toggleMeasurementsButton.layer.cornerRadius = 8
        toggleMeasurementsButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        toggleMeasurementsButton.isHidden = true
        toggleMeasurementsButton.translatesAutoresizingMaskIntoConstraints = false
        toggleMeasurementsButton.addTarget(self, action: #selector(toggleMeasurementsButtonTapped(_:)), for: .touchUpInside)
        view.addSubview(toggleMeasurementsButton)

        loadingOverlay = UIView()
        loadingOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        loadingOverlay.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.isHidden = true
        view.addSubview(loadingOverlay)

        loadingIndicator = UIActivityIndicatorView(style: .large)
        loadingIndicator.color = UIColor.white
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.addSubview(loadingIndicator)

        // Set up constraints
        setupConstraints()
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            // ARSCNView fills the entire view
            sceneView.topAnchor.constraint(equalTo: view.topAnchor),
            sceneView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sceneView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Instruction label
            instructionLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            instructionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            instructionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            // Progress view
            progressView.topAnchor.constraint(equalTo: instructionLabel.bottomAnchor, constant: 16),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            // Status label
            statusLabel.topAnchor.constraint(equalTo: progressView.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            // Measurement label
            measurementLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
            measurementLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            measurementLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            measurementLabel.heightAnchor.constraint(equalToConstant: 100),
            measurementLabel.bottomAnchor.constraint(lessThanOrEqualTo: startButton.topAnchor, constant: -20),

            // Cancel button (bottom button)
            cancelButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            cancelButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            cancelButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            cancelButton.heightAnchor.constraint(equalToConstant: 50),

            // Save button (above cancel)
            exportButton.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -12),
            exportButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            exportButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            // Start button (above save)
            startButton.bottomAnchor.constraint(equalTo: exportButton.topAnchor, constant: -12),
            startButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            startButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            // Hidden buttons (for reference, but not visible)
            logoutButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            logoutButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            logoutButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            logoutButton.heightAnchor.constraint(equalToConstant: 44),

            toggleMeasurementsButton.bottomAnchor.constraint(equalTo: startButton.topAnchor, constant: -12),
            toggleMeasurementsButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            toggleMeasurementsButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            toggleMeasurementsButton.heightAnchor.constraint(equalToConstant: 44),

            loadingOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            loadingOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            loadingOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            loadingIndicator.centerXAnchor.constraint(equalTo: loadingOverlay.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: loadingOverlay.centerYAnchor)
        ])

        exportButtonHeightConstraint = exportButton.heightAnchor.constraint(equalToConstant: measurementMode == .recommend ? 50 : 0)
        exportButtonHeightConstraint?.isActive = true

        startButtonHeightConstraint = startButton.heightAnchor.constraint(equalToConstant: 50)
        startButtonHeightConstraint?.isActive = true

        if measurementMode == .recommend {
            startButton.isHidden = true
            startButton.isEnabled = false
            startButtonHeightConstraint?.constant = 0
            instructionLabel.text = "Press Recommend to start measurement and get mask recommendations."
            statusLabel.text = "Ready to recommend"
        }
    }

    func setLoading(_ isLoading: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.loadingOverlay.isHidden = !isLoading
            if isLoading {
                self.loadingIndicator.startAnimating()
            } else {
                self.loadingIndicator.stopAnimating()
            }
        }
    }

    private func setupARKit() {
        // Check if device supports ARKit and True Depth
        guard ARFaceTrackingConfiguration.isSupported else {
            showError("ARKit face tracking is not supported on this device")
            return
        }

        // Configure ARSCNView
        sceneView.delegate = self
        sceneView.session.delegate = self
        sceneView.automaticallyUpdatesLighting = true

        // Add face geometry visualization
        setupFaceGeometry()

        // Setup measurement overlays
        setupMeasurementOverlays()
    }

    private func setupFaceGeometry() {
        // Create a simple face geometry visualization
        let faceGeometry = ARSCNFaceGeometry(device: sceneView.device!)
        let material = faceGeometry?.firstMaterial
        material?.diffuse.contents = UIColor.systemBlue.withAlphaComponent(0.3)
        material?.isDoubleSided = true
    }

    private func setupMeasurementOverlays() {
        // Create landmark point nodes for each measurement pair
        let allIndices = Set(FacialMeasurementPairs.commonPairs.flatMap { [$0.0, $0.1] })

        for index in allIndices {
            let pointNode = createLandmarkPointNode(index: index)
            landmarkNodes[index] = pointNode
        }

        // Create line nodes for each measurement pair
        for (index1, index2) in FacialMeasurementPairs.commonPairs {
            let lineNode = createMeasurementLineNode(from: index1, to: index2)
            let key = "\(index1)-\(index2)"
            measurementLineNodes[key] = lineNode
        }
    }

    private func createLandmarkPointNode(index: Int) -> SCNNode {
        // Create a small white sphere for the landmark point
        let sphere = SCNSphere(radius: 0.001) // 1mm radius
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.white
        material.emission.contents = UIColor.white.withAlphaComponent(0.5)
        sphere.materials = [material]

        let pointNode = SCNNode(geometry: sphere)
        pointNode.name = "landmark_\(index)"

        // Add text label for the landmark index
        let textGeometry = SCNText(string: "\(index)", extrusionDepth: 0.0001)
        textGeometry.font = UIFont.systemFont(ofSize: 0.002)
        textGeometry.firstMaterial?.diffuse.contents = UIColor.white
        textGeometry.firstMaterial?.emission.contents = UIColor.white.withAlphaComponent(0.8)

        let textNode = SCNNode(geometry: textGeometry)
        textNode.position = SCNVector3(0, 0.002, 0) // Position text above the point
        pointNode.addChildNode(textNode)

        return pointNode
    }

    private func createMeasurementLineNode(from index1: Int, to index2: Int) -> SCNNode {
        // Create a red line between two landmarks
        let lineGeometry = SCNCylinder(radius: 0.0002, height: 1.0) // 0.2mm radius
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.red
        material.emission.contents = UIColor.red.withAlphaComponent(0.3)
        lineGeometry.materials = [material]

        let lineNode = SCNNode(geometry: lineGeometry)
        lineNode.name = "line_\(index1)_\(index2)"

        return lineNode
    }

    private func addMeasurementOverlays(to faceNode: SCNNode, faceGeometry: ARFaceGeometry) {
        // Add landmark point nodes
        for (index, pointNode) in landmarkNodes {
            if index < faceGeometry.vertices.count {
                let vertex = faceGeometry.vertices[index]
                pointNode.position = SCNVector3(vertex.x, vertex.y, vertex.z)
                faceNode.addChildNode(pointNode)
            }
        }

        // Add measurement line nodes
        for (key, lineNode) in measurementLineNodes {
            let components = key.split(separator: "-")
            if components.count == 2,
               let index1 = Int(components[0]),
               let index2 = Int(components[1]),
               index1 < faceGeometry.vertices.count,
               index2 < faceGeometry.vertices.count {

                let vertex1 = faceGeometry.vertices[index1]
                let vertex2 = faceGeometry.vertices[index2]

                // Position the line between the two vertices
                positionLineNode(lineNode, from: vertex1, to: vertex2)
                faceNode.addChildNode(lineNode)
            }
        }
    }

    private func positionLineNode(_ lineNode: SCNNode, from vertex1: SIMD3<Float>, to vertex2: SIMD3<Float>) {
        // Calculate the midpoint
        let midpoint = SIMD3<Float>(
            (vertex1.x + vertex2.x) / 2,
            (vertex1.y + vertex2.y) / 2,
            (vertex1.z + vertex2.z) / 2
        )

        // Calculate the distance between vertices
        let distance = sqrt(
            pow(vertex2.x - vertex1.x, 2) +
            pow(vertex2.y - vertex1.y, 2) +
            pow(vertex2.z - vertex1.z, 2)
        )

        // Position the line at the midpoint
        lineNode.position = SCNVector3(midpoint.x, midpoint.y, midpoint.z)

        // Scale the line to the correct length
        lineNode.scale = SCNVector3(1, distance, 1)

        // Orient the line to point from vertex1 to vertex2
        let direction = SIMD3<Float>(
            vertex2.x - vertex1.x,
            vertex2.y - vertex1.y,
            vertex2.z - vertex1.z
        )

        // Calculate rotation to align the line
        let up = SIMD3<Float>(0, 1, 0)
        let right = cross(up, direction)
        let forward = cross(right, up)

        // Create rotation matrix
        let rotationMatrix = simd_float4x4(
            SIMD4<Float>(right.x, right.y, right.z, 0),
            SIMD4<Float>(up.x, up.y, up.z, 0),
            SIMD4<Float>(forward.x, forward.y, forward.z, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )

        lineNode.transform = SCNMatrix4(rotationMatrix)
    }

    private func updateMeasurementOverlays(faceGeometry: ARFaceGeometry) {
        // Update landmark point positions
        for (index, pointNode) in landmarkNodes {
            if index < faceGeometry.vertices.count {
                let vertex = faceGeometry.vertices[index]
                pointNode.position = SCNVector3(vertex.x, vertex.y, vertex.z)
            }
        }

        // Update measurement line positions
        for (key, lineNode) in measurementLineNodes {
            let components = key.split(separator: "-")
            if components.count == 2,
               let index1 = Int(components[0]),
               let index2 = Int(components[1]),
               index1 < faceGeometry.vertices.count,
               index2 < faceGeometry.vertices.count {

                let vertex1 = faceGeometry.vertices[index1]
                let vertex2 = faceGeometry.vertices[index2]
                positionLineNode(lineNode, from: vertex1, to: vertex2)
            }
        }
    }

    private func setupDelegates() {
        measurementEngine.delegate = self
        dataExportManager.delegate = self
    }

    private func startARSession() {
        let configuration = ARFaceTrackingConfiguration()
        configuration.isLightEstimationEnabled = true
        configuration.maximumNumberOfTrackedFaces = 1

        sceneView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    // MARK: - Actions
    @objc func startButtonTapped(_ sender: UIButton) {
        if isMeasuring {
            stopMeasurement()
        } else {
            startMeasurement()
        }
    }

    @objc func saveButtonTapped(_ sender: UIButton) {
        switch measurementMode {
        case .recommend:
            if isMeasuring {
                return
            }
            if let aggregated = aggregatedMeasurementsIfAvailable() {
                onRecommend?(aggregated)
                return
            }

            shouldRecommendWhenMeasurementCompletes = true
            exportButton.isEnabled = false
            exportButton.setTitle("Measuring...", for: .normal)
            startMeasurement()
        case .contribute:
            saveData()
        }
    }

    @objc func cancelButtonTapped(_ sender: UIButton) {
        // Dismiss the view controller and return to main menu
        dismiss(animated: true)
    }

    private func openViewDataPage() {
        // Check if user is authenticated
        guard let authService = authService, authService.isAuthenticated else {
            // User not authenticated, dismiss and return to login
            dismiss(animated: true)
            return
        }
        
        // Check if user is selected
        guard let selectedUser = selectedUser,
              let managedId = selectedUser.managedId else {
            showError("No user selected")
            return
        }
        
        // Construct URL
        let urlString = "http://www.breathesafe.xyz/#/respirator_user/\(managedId)?tabToShow=Facial+Measurements"
        
        guard let url = URL(string: urlString) else {
            showError("Invalid URL")
            return
        }
        
        // Open in Safari
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    @objc func logoutButtonTapped(_ sender: UIButton) {
        logout()
    }


    @objc func switchUserButtonTapped(_ sender: UIButton) {
        showManagedUsersSelection()
    }

    private func toggleMeasurements() {
        isMeasurementsVisible.toggle()
        measurementLabel.isHidden = !isMeasurementsVisible
        
        // If showing measurements again, refresh the display
        if isMeasurementsVisible {
            let averageMeasurements = measurementEngine.getAverageMeasurements()
            displayMeasurements(averageMeasurements)
        }
    }

    @objc func toggleMeasurementsButtonTapped(_ sender: UIButton) {
        toggleMeasurements()
    }

    // MARK: - Measurement Control
    private func startMeasurement() {
        isMeasuring = true
        measurementCount = 0
        measurementEngine.clearHistory()

        if measurementMode == .contribute {
            startButton.setTitle("Stop Measurement", for: .normal)
            startButton.backgroundColor = UIColor.systemRed
        }
        exportButton.isEnabled = false
        progressView.isHidden = false
        progressView.progress = 0.0

        instructionLabel.text = "Keep your face steady and centered in the camera view. Measurements are being collected..."
        statusLabel.text = "Collecting measurements..."

        // Update UI to show measurement is active
        UIView.animate(withDuration: 0.3) {
            self.view.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.1)
        }
    }

    private func stopMeasurement() {
        isMeasuring = false

        if measurementMode == .contribute {
            startButton.setTitle("Start Measurement", for: .normal)
            startButton.backgroundColor = UIColor.systemBlue
        }
        progressView.isHidden = true

        instructionLabel.text = measurementMode == .recommend
            ? "Measurement complete! Getting recommendations..."
            : "Measurement complete! You can now export your data."
        statusLabel.text = "Measurement complete"

        // Reset background color
        UIView.animate(withDuration: 0.3) {
            self.view.backgroundColor = UIColor.systemBackground
        }

        // Show final measurements
        let averageMeasurements = measurementEngine.getAverageMeasurements()
        displayMeasurements(averageMeasurements)

        if measurementMode == .recommend {
            exportButton.setTitle("Recommend", for: .normal)
            exportButton.isEnabled = true
            if shouldRecommendWhenMeasurementCompletes {
                shouldRecommendWhenMeasurementCompletes = false
                handleRecommend()
            }
        } else {
            // Contribute flow: one button does measurement + save.
            saveData()
        }
    }

    // MARK: - Data Display
    private func displayMeasurements(_ measurements: [String: Float]) {
        guard isMeasurementsVisible else { return }
        
        if measurements.isEmpty {
            measurementLabel.text = "Collecting measurements...\n\nMeasurements will appear here as they are collected."
            return
        }
        
        let title = isMeasuring ? "Current Measurements (Live):\n\n" : "Average Measurements:\n\n"
        var measurementText = title

        for (key, value) in measurements.sorted(by: { $0.key < $1.key }) {
            let description = FacialMeasurementPairs.pairDescriptions[key] ?? key
            measurementText += "\(description): \(String(format: "%.3f", value))\n"
        }

        measurementLabel.text = measurementText
    }

    private func aggregatedMeasurementsIfAvailable() -> [String: Double]? {
        let exported = measurementEngine.exportMeasurements()
        return computeAggregatedMeasurements(from: exported)
    }

    private func handleRecommend() {
        let exported = measurementEngine.exportMeasurements()
        guard let aggregated = computeAggregatedMeasurements(from: exported) else {
            showError("Missing required facial measurements. Please re-run the measurement.")
            return
        }
        onRecommend?(aggregated)
    }

    private func computeAggregatedMeasurements(from exported: [String: Any]) -> [String: Double]? {
        guard let averageMeasurements = exported["average_measurements"] as? [String: Any] else {
            return nil
        }

        let noseKeys = [
            "160-371", "371-367", "367-387", "387-14",
            "609-802", "802-798", "798-14", "14-818"
        ]
        let strapKeys = [
            "967-464", "464-456", "456-451", "451-455",
            "999-1027", "1027-884", "884-883", "883-879"
        ]
        let topCheekKeys = [
            "879-600", "600-756", "756-862", "862-753", "753-594", "594-582", "582-609",
            "451-151", "151-321", "321-434", "434-318", "318-145", "145-133", "133-160"
        ]
        let midCheekKeys = [
            "509-893", "893-894", "894-881", "881-880", "880-879",
            "60-478", "478-479", "479-453", "453-452", "452-451"
        ]
        let chinKeys = [
            "1049-983", "983-982", "982-1050", "1050-1051", "1051-1052", "1052-1053", "1053-509",
            "1049-984", "984-985", "985-986", "986-987", "987-988", "988-989", "989-60"
        ]

        func sum(keys: [String]) -> Double? {
            var total = 0.0
            var found = false
            for key in keys {
                guard let entry = averageMeasurements[key] as? [String: Any] else {
                    continue
                }
                if let value = entry["value"] as? Double, value > 0 {
                    total += value
                    found = true
                } else if let number = entry["value"] as? NSNumber, number.doubleValue > 0 {
                    total += number.doubleValue
                    found = true
                }
            }
            return found ? total : nil
        }

        guard let nose = sum(keys: noseKeys),
              let strap = sum(keys: strapKeys),
              let topCheek = sum(keys: topCheekKeys),
              let midCheek = sum(keys: midCheekKeys),
              let chin = sum(keys: chinKeys) else {
            return nil
        }

        return [
            "nose_mm": nose,
            "strap_mm": strap,
            "top_cheek_mm": topCheek,
            "mid_cheek_mm": midCheek,
            "chin_mm": chin
        ]
    }

    // MARK: - Data Save
    
    private func saveData() {
        let measurements = measurementEngine.exportMeasurements()

        // Always try to save to server first if authenticated
        if authService?.isAuthenticated == true && selectedUser != nil {
            sendToServer(measurements)
        } else {
            // User is not authenticated, show local save options
            showLocalSaveOptions(measurements)
        }
    }

    private func showLocalSaveOptions(_ measurements: [String: Any]) {
        let alert = UIAlertController(title: "Save Data (Local Only)", message: "No internet connection. Your data will be saved locally.", preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "Save JSON to Files", style: .default) { _ in
            if let fileURL = self.dataExportManager.saveToLocalFile(measurements) {
                self.showSuccess("Data saved locally to: \(fileURL.lastPathComponent)")
                // Navigate back after local save
                self.navigateBackToAddEditUser()
            }
        })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        // For iPad
        if let popover = alert.popoverPresentationController {
            popover.sourceView = exportButton
            popover.sourceRect = exportButton.bounds
        }

        present(alert, animated: true)
    }

    private func sendToServer(_ measurements: [String: Any]) {
        guard let selectedUser = selectedUser,
              let apiClient = apiClient else {
            showError("No user selected or API client not available")
            return
        }

        guard let authService = authService, authService.isAuthenticated else {
            showError("User is not authenticated. Please login first.")
            return
        }

        // Show loading indicator
        exportButton.isEnabled = false
        exportButton.setTitle("Saving...", for: .normal)

        // Export to Rails backend
        apiClient.exportFacialMeasurements(measurements, for: selectedUser.managedId ?? 0) { [weak self] result in
            DispatchQueue.main.async {
                self?.exportButton.isEnabled = true
                self?.exportButton.setTitle("Save", for: .normal)
                
                switch result {
                case .success:
                    self?.showSuccessAndNavigateBack("Data saved successfully!")
                case .failure(let error):
                    // If there's a network error, offer to save offline
                    if case APIError.networkError = error {
                        self?.offerLocalSave(measurements, error: error)
                    } else {
                        self?.showError("Failed to save data: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    
    private func offerLocalSave(_ measurements: [String: Any], error: Error) {
        let alert = UIAlertController(
            title: "No Internet Connection",
            message: "Unable to save to server. Would you like to save locally instead?",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Save Locally", style: .default) { [weak self] _ in
            if let fileURL = self?.dataExportManager.saveToLocalFile(measurements) {
                self?.showSuccessAndNavigateBack("Data saved locally to: \(fileURL.lastPathComponent)")
            } else {
                self?.showError("Failed to save locally")
            }
        })
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        present(alert, animated: true)
    }
    
    private func navigateBackToAddEditUser() {
        // Dismiss the navigation controller to return to AddEditUserViewController
        // Check if we're in a navigation controller
        if let navController = navigationController {
            // If we're in a nav controller, dismiss it
            navController.dismiss(animated: true)
        } else {
            // Otherwise, dismiss ourselves
            dismiss(animated: true)
        }
    }

    // TODO: Uncomment these methods once the new model files are added to the Xcode project
    private func saveOffline(_ measurements: [String: Any]) {
        guard let selectedUser = selectedUser,
              let offlineSyncManager = offlineSyncManager else {
            return
        }

        offlineSyncManager.saveMeasurementsOffline(measurements, for: selectedUser.managedId ?? 0)
        showSuccess("Data saved offline and will sync when connected")
    }

    private func loadManagedUsers() {
        guard let authService = authService, authService.isAuthenticated else {
            return
        }

        authService.loadManagedUsers { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let users):
                    self?.managedUsers = users
                case .failure(let error):
                    self?.showError("Failed to load managed users: \(error.localizedDescription)")
                }
            }
        }
    }

    private func showManagedUsersSelection() {
        // Check if we have managed users
        if managedUsers.isEmpty {
            let alert = UIAlertController(
                title: "No Managed Users",
                message: "There are no managed (respirator) users currently. Please create at least one.",
                preferredStyle: .alert
            )
            
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.openRespiratorUsersPage()
            })
            
            present(alert, animated: true)
            return
        }

        let alert = UIAlertController(
            title: "Switch Respirator User",
            message: "Choose a user to switch to:",
            preferredStyle: .actionSheet
        )

        for user in managedUsers {
            let title: String
            if let selectedUser = selectedUser,
               user.managedId == selectedUser.managedId {
                // Mark currently selected user with checkmark
                title = "✓ \(user.displayName)"
            } else {
                title = user.displayName
            }
            
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.switchToUser(user)
            })
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        // For iPad
        if let popover = alert.popoverPresentationController {
            popover.sourceView = self.view
            popover.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        present(alert, animated: true)
    }

    private func switchToUser(_ user: ManagedUser) {
        // Stop measurement if currently measuring
        if isMeasuring {
            isMeasuring = false
            measurementEngine.clearHistory()
        }
        
        // Clear/reset current measurements
        measurementEngine.clearHistory()
        measurementCount = 0
        shouldRecommendWhenMeasurementCompletes = false
        
        // Update selected user
        selectedUser = user
        
        // Update title
        title = "Face Measurement - \(user.displayName)"
        
        // Reset UI
        startButton.setTitle("Start Measurement", for: .normal)
        startButton.backgroundColor = UIColor.systemBlue
        progressView.isHidden = true
        progressView.progress = 0.0

        if measurementMode == .recommend {
            startButton.isHidden = true
            startButton.isEnabled = false
            startButtonHeightConstraint?.constant = 0
            exportButton.isHidden = false
            exportButtonHeightConstraint?.constant = 50
            exportButton.isEnabled = true
            exportButton.setTitle("Recommend", for: .normal)
            statusLabel.text = "Ready to recommend"
            instructionLabel.text = "Press Recommend to start measurement and get mask recommendations."
            measurementLabel.text = "Measurements will appear here after recommendation starts measurement collection.\n\nPress 'Recommend' to begin."
        } else {
            startButton.isHidden = false
            startButton.isEnabled = true
            startButtonHeightConstraint?.constant = 50
            exportButton.isHidden = true
            exportButtonHeightConstraint?.constant = 0
            exportButton.isEnabled = false
            statusLabel.text = "Ready to start"
            instructionLabel.text = "Position your face close to the camera (less than 12 inches away) in portrait mode. Remove glasses, hats, or anything covering your face."
            measurementLabel.text = "Measurements will appear here after you start a measurement.\n\nPress 'Start Measurement' to begin collecting facial measurement data."
        }

        // Reset background color
        UIView.animate(withDuration: 0.3) {
            self.view.backgroundColor = UIColor.systemBackground
        }
    }

    private func openRespiratorUsersPage() {
        guard let url = URL(string: "https://www.breathesafe.xyz/#/respirator_users") else {
            showError("Invalid URL")
            return
        }
        
        let safariVC = SFSafariViewController(url: url)
        present(safariVC, animated: true)
    }

    private func logout() {
        guard let authService = authService else {
            return
        }

        let alert = UIAlertController(
            title: "Logout",
            message: "Are you sure you want to logout?",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "Logout", style: .destructive) { [weak self] _ in
            authService.logout { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        // Dismiss the current view controller and return to login
                        self?.dismiss(animated: true)
                    case .failure(let error):
                        self?.showError("Logout failed: \(error.localizedDescription)")
                    }
                }
            }
        })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }


    // MARK: - Helper Methods
    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func showSuccess(_ message: String) {
        let alert = UIAlertController(title: "Success", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
    
    private func showSuccessAndNavigateBack(_ message: String) {
        let alert = UIAlertController(title: "Success", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            // Navigate back immediately after user dismisses the alert
            self?.navigateBackToAddEditUser()
        })
        present(alert, animated: true)
    }
}

// MARK: - ARSCNViewDelegate
extension FaceMeasurementViewController: ARSCNViewDelegate {
    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard let faceAnchor = anchor as? ARFaceAnchor else { return }

        // Create face geometry visualization
        guard let device = sceneView.device else {
            return
        }

        let faceGeometry = ARSCNFaceGeometry(device: device)
        let faceNode = SCNNode(geometry: faceGeometry)

        let material = faceGeometry?.firstMaterial
        material?.diffuse.contents = UIColor.systemBlue.withAlphaComponent(0.3)
        material?.isDoubleSided = true

        node.addChildNode(faceNode)

        // Add measurement overlays to the face node
        addMeasurementOverlays(to: node, faceGeometry: faceAnchor.geometry)
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let faceAnchor = anchor as? ARFaceAnchor else { return }

        // Update the face geometry visualization if it exists
        if let faceGeometry = node.geometry as? ARSCNFaceGeometry {
            faceGeometry.update(from: faceAnchor.geometry)
        }

        // Update measurement overlays
        updateMeasurementOverlays(faceGeometry: faceAnchor.geometry)

        // Process facial landmarks for measurement
        if isMeasuring {
            let landmarks = FacialLandmarks(from: faceAnchor.geometry, timestamp: CACurrentMediaTime())
            measurementEngine.processLandmarks(landmarks)
        }
    }
}

// MARK: - ARSessionDelegate
extension FaceMeasurementViewController: ARSessionDelegate {
    func session(_ session: ARSession, didFailWithError error: Error) {
        showError("ARKit session failed: \(error.localizedDescription)")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        statusLabel.text = "Session interrupted"
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        statusLabel.text = "Session resumed"
        startARSession()
    }
}

// MARK: - MeasurementEngineDelegate
extension FaceMeasurementViewController: MeasurementEngineDelegate {
    func measurementEngine(_ engine: MeasurementEngine, didUpdateMeasurements measurements: [String: Float]) {
        DispatchQueue.main.async {
            self.measurementCount += 1
            let progress = Float(self.measurementCount) / Float(self.requiredMeasurements)
            self.progressView.progress = min(progress, 1.0)

            // Update status
            self.statusLabel.text = "Collected \(self.measurementCount) measurements"

            // Show current measurements
            self.displayMeasurements(measurements)

            // Auto-stop when enough measurements collected
            if self.measurementCount >= self.requiredMeasurements {
                self.stopMeasurement()
            }
        }
    }

    func measurementEngine(_ engine: MeasurementEngine, didEncounterError error: Error) {
        DispatchQueue.main.async {
            self.showError("Measurement error: \(error.localizedDescription)")
        }
    }
}

// MARK: - DataExportManagerDelegate
extension FaceMeasurementViewController: DataExportManagerDelegate {
    func dataExportManager(_ manager: DataExportManager, didCompleteExport data: [String: Any]) {
        DispatchQueue.main.async {
            self.showSuccess("Data exported successfully!")
        }
    }

    func dataExportManager(_ manager: DataExportManager, didEncounterError error: Error) {
        DispatchQueue.main.async {
            self.showError("Export error: \(error.localizedDescription)")
        }
    }
}
