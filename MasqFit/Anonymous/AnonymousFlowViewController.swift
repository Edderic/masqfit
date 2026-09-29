import UIKit
import CoreImage

/// Participant state is intentionally ephemeral; only consented queue items persist.
final class AnonymousFlowViewController: UIViewController {
    enum Mode { case measureOnly, contribute }
    let mode: Mode
    private var credential: String?
    private var previousMeasurements: PreviousAnonymousMeasurements?
    private let measurementLookup = AnonymousMeasurementLookup()
    private var lookupTask: URLSessionDataTask?
    private var lookupID = UUID()
    private var loadingMeasurements = false
    private var lookupMessage: String?
    private var lookupFailed = false
    private var measurements: FacialAggregates?
    private var records: [MFTCRecord] = []
    private var sourceKeys = Set<String>()
    private var reviewRecords: [MFTCRecord] = []
    private let stack = UIStackView()
    private var actions: [Int: () -> Void] = [:]
    private var submitted = false

    init(mode: Mode) { self.mode = mode; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        title = mode == .measureOnly ? "Measure only" : "Contribute anonymously"
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        if mode == .contribute {
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Queue", style: .plain, target: self, action: #selector(showQueue))
            navigationItem.rightBarButtonItem?.accessibilityLabel = "Submission queue"
        }
        isModalInPresentation = true
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(scroll)
        stack.axis = .vertical; stack.spacing = 18; stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
        NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)])
        render()
    }
    private func clear() { stack.arrangedSubviews.forEach { $0.removeFromSuperview() }; actions.removeAll() }
    private func label(_ text: String, large: Bool = false) {
        let label = UILabel(); label.text = text; label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: large ? .title2 : .body); label.adjustsFontForContentSizeCategory = true
        stack.addArrangedSubview(label)
    }
    private func button(_ title: String, action: @escaping () -> Void) {
        let button = UIButton(type: .system); button.setTitle(title, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline); button.titleLabel?.numberOfLines = 0
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        button.tag = actions.count; actions[button.tag] = action
        button.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside); stack.addArrangedSubview(button)
    }
    @objc private func tapped(_ sender: UIButton) { actions[sender.tag]?() }
    private func render() {
        clear()
        if mode == .contribute && credential == nil {
            label("Contribute without a name or email. Save your participant code to link future visits. Anyone with your code can access and reuse your saved measurements and contribute under the same identity.")
            button("New participant") { [weak self] in
                guard let self = self else { return }
                do { self.credential = try AnonymousIdentity.create(); self.render() } catch { self.error(error.localizedDescription) }
            }
            button("Scan saved participant code") { [weak self] in self?.scanIdentity() }
            button("Enter saved participant code") { [weak self] in self?.enterIdentity() }
            button("Submission queue") { [weak self] in self?.showQueue() }
            return
        }
        if let credential = credential {
            label("Participant code", large: true)
            if let image = qrImage(AnonymousIdentity.prefix + credential) {
                let imageView = UIImageView(image: image); imageView.contentMode = .scaleAspectFit
                imageView.accessibilityLabel = "Recovery QR code. Use Save participant code to keep a copy."
                imageView.heightAnchor.constraint(equalToConstant: 190).isActive = true; stack.addArrangedSubview(imageView)
            }
            button("Save participant code") { [weak self] in
                guard let self = self else { return }
                var items: [Any] = [AnonymousIdentity.prefix + credential]
                if let image = self.qrImage(AnonymousIdentity.prefix + credential) { items.append(image) }
                self.share(items)
            }
            label("Keep this code yourself. This phone forgets the active participant when you finish. Keep it private: anyone with this code can access and reuse your saved measurements. Lost codes cannot be recovered by name or email.")
        } else { label("Scan to display five facial measurements. Nothing is uploaded. Copy or share only if you choose.") }
        if submitted {
            label("Submission saved. Check the queue for delivery status.", large: true)
            button("Submission queue") { [weak self] in self?.showQueue() }
        } else {
            if loadingMeasurements { label("Looking for previous measurements…") }
            if let message = lookupMessage { label(message) }
            if lookupFailed {
                button("Try loading previous measurements again") { [weak self] in self?.loadPreviousMeasurements() }
            }
            if let previous = previousMeasurements {
                label("Use my previous measurements ✓", large: true)
                label(previous.summary + " You can scan again if your measurements have changed.")
            }
            if let measurements = measurements {
                label(measurements.text, large: true)
                if mode == .measureOnly {
                    button("Copy measurements") { UIPasteboard.general.setItems([["public.utf8-plain-text": measurements.text]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)]) }
                    button("Share CSV") { [weak self] in self?.shareCSV(measurements.csv) }
                }
            }
            button(measurements == nil ? "Scan face" : "Scan again") { [weak self] in self?.capture() }
            if mode == .contribute && measurements != nil {
                label("\(records.count) fit tests selected. QR import is optional.")
                for (index, record) in records.enumerated() {
                    label(summary(record.test))
                    button("Change testing mode for fit test \(index + 1)") { [weak self] in
                        self?.chooseTestingMode(for: record.sourceKey)
                    }
                    button("Remove fit test \(index + 1)") { [weak self] in guard let self = self else { return }
                        self.sourceKeys.remove(self.records[index].sourceKey)
                        self.records.remove(at: index); self.render() }
                }
                button("Import MFTC results") { [weak self] in self?.scanTests() }
                button("Review and submit") { [weak self] in self?.consent() }
            }
        }
        button("Next participant") { [weak self] in self?.confirmClear(close: false) }
    }
    private func cancelLookup() {
        lookupID = UUID(); lookupTask?.cancel(); lookupTask = nil
        loadingMeasurements = false; lookupFailed = false; lookupMessage = nil
    }
    private func useSavedCode(_ code: String) {
        cancelLookup(); credential = code; measurements = nil; previousMeasurements = nil
        loadPreviousMeasurements()
    }
    private func loadPreviousMeasurements() {
        guard let credential = credential else { return }
        cancelLookup(); loadingMeasurements = true
        let requestID = lookupID
        render()
        lookupTask = measurementLookup.fetch(credential: credential) { [weak self] result in
            guard let self = self, self.lookupID == requestID, self.credential == credential else { return }
            self.lookupTask = nil; self.loadingMeasurements = false
            switch result {
            case .success(let previous):
                self.previousMeasurements = previous; self.measurements = previous?.aggregates
                self.lookupMessage = previous == nil ? "No saved measurements were found for this code. Scan your face to continue. Measurements still waiting in the submission queue are not available here yet." : nil
            case .failure:
                self.lookupFailed = true
                self.lookupMessage = "Could not load previous measurements. Try again when connected, or scan your face."
            }
            self.render()
        }
    }
    private func capture() {
        cancelLookup(); render()
        let capture = FaceMeasurementViewController(); capture.measurementMode = .captureOnly
        capture.onCapture = { [weak self, weak capture] value in
            capture?.dismiss(animated: true) { self?.previousMeasurements = nil; self?.measurements = value; self?.render() }
        }
        let nav = UINavigationController(rootViewController: capture); nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }
    private func scanner(_ callback: @escaping ([String]) -> Void) {
        let scanner = QRScannerViewController(); scanner.onCodes = callback
        let nav = UINavigationController(rootViewController: scanner); nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }
    private func scanIdentity() {
        scanner { [weak self] codes in
            guard let code = codes.compactMap(AnonymousIdentity.parse).first else { self?.error("No valid participant code found."); return }
            self?.useSavedCode(code)
        }
    }
    private func enterIdentity() {
        let alert = UIAlertController(title: "Saved participant code", message: "Paste the code you saved at a previous visit.", preferredStyle: .alert)
        alert.addTextField { $0.autocapitalizationType = .none; $0.autocorrectionType = .no }
        alert.addAction(UIAlertAction(title: "Use code", style: .default) { [weak self, weak alert] _ in
            guard let code = AnonymousIdentity.parse(alert?.textFields?.first?.text ?? "") else { self?.error("That participant code is invalid."); return }
            self?.useSavedCode(code)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); present(alert, animated: true)
    }
    private func scanTests() {
        scanner { [weak self] codes in
            guard let self = self else { return }
            do {
                var seen = self.sourceKeys
                let imported = try codes.flatMap(MFTCImport.decode)
                self.reviewRecords = imported.filter { seen.insert($0.sourceKey).inserted }
                guard self.records.count + self.reviewRecords.count <= 100 else { self.reviewRecords = []; throw MFTCImport.ImportError.invalid }
                if self.reviewRecords.isEmpty { self.error("These results have already been imported.") }
                else { self.reviewNext() }
            } catch { self.error(error.localizedDescription) }
        }
    }
    private func reviewNext() {
        guard !reviewRecords.isEmpty else { render(); return }
        let record = reviewRecords.removeFirst()
        let alert = UIAlertController(title: "Does this test belong to this participant?",
            message: "MFTC participant: \(record.participant)\n\n\(summary(record.test))\n\nThe MFTC participant label is shown only on this phone and will not be uploaded.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Select and review fields", style: .default) { [weak self] _ in self?.edit(record) })
        alert.addAction(UIAlertAction(title: "Skip", style: .default) { [weak self] _ in self?.reviewNext() })
        alert.addAction(UIAlertAction(title: "Stop importing", style: .cancel) { [weak self] _ in self?.reviewRecords = []; self?.render() })
        present(alert, animated: true)
    }
    private func edit(_ record: MFTCRecord) {
        let alert = UIAlertController(title: "Review shared text", message: "Keep only the mask model and protocol name. Remove names, event details, or other identifying text. Find matches sends only the reviewed mask name to BreatheSafe to suggest catalog entries.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Mask model (optional)"; $0.text = record.test.mask }
        alert.addTextField { $0.placeholder = "Protocol (optional)"; $0.text = record.test.protocolName }
        alert.addAction(UIAlertAction(title: "Keep unresolved", style: .default) { [weak self, weak alert] _ in
            var reviewed = record
            reviewed.test.mask = String((alert?.textFields?[0].text ?? "").prefix(200))
            reviewed.test.protocolName = String((alert?.textFields?[1].text ?? "").prefix(200))
            self?.accept(reviewed)
        })
        alert.addAction(UIAlertAction(title: "Find matches", style: .default) { [weak self, weak alert] _ in
            var reviewed = record
            reviewed.test.mask = String((alert?.textFields?[0].text ?? "").prefix(200))
            reviewed.test.protocolName = String((alert?.textFields?[1].text ?? "").prefix(200))
            self?.matchMask(reviewed)
        })
        alert.addAction(UIAlertAction(title: "Skip", style: .cancel) { [weak self] _ in self?.reviewNext() })
        present(alert, animated: true)
    }
    private func matchMask(_ record: MFTCRecord) {
        // The user has reviewed the label before it is sent for suggestions.
        let picker = AnonymousMaskPickerViewController()
        picker.importedName = record.test.mask
        picker.onSelect = { [weak self] id, name, proposed in
            var record = record; record.test.maskID = id; record.test.proposeMask = proposed
            if let name = name { record.test.mask = name }
            self?.accept(record)
        }
        let nav = UINavigationController(rootViewController: picker)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }
    private func accept(_ record: MFTCRecord) {
        sourceKeys.insert(record.sourceKey)
        // Keep source keys for deduplication, but discard the participant label after review.
        records.append(MFTCRecord(sourceKey: record.sourceKey, participant: "", test: record.test))
        reviewNext()
    }
    private func chooseTestingMode(for sourceKey: String) {
        guard let record = records.first(where: { $0.sourceKey == sourceKey }) else { return }
        let alert = UIAlertController(title: "Testing mode (optional)",
            message: "Mask: \(record.test.mask)\nCurrent: \((record.test.testingMode ?? .unknown).label)\n\nChoose the mode used by the fit-testing instrument. This is separate from the mask’s filtration rating. Leave Unknown if you’re unsure.", preferredStyle: .alert)
        for mode in FitTestingMode.allCases {
            alert.addAction(UIAlertAction(title: mode.label, style: .default) { [weak self] _ in
                guard let self = self, let index = self.records.firstIndex(where: { $0.sourceKey == sourceKey }) else { return }
                self.records[index].test.testingMode = mode
                self.render()
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
    private func summary(_ test: AnonymousFitTest) -> String {
        let scores = test.exercises.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.map { "Exercise \($0): \(test.exercises[$0]!)" }.joined(separator: "\n")
        let catalog = test.proposeMask ? "New mask proposed — admins will be notified for review after submission"
            : test.maskID == nil ? "Not matched to catalog" : "Matched to catalog: \(test.mask)"
        return "Mask: \(test.mask.isEmpty ? "Unspecified" : test.mask)\nTesting mode: \((test.testingMode ?? .unknown).label)\nProtocol: \(test.protocolName.isEmpty ? "Unspecified" : test.protocolName)\n\(scores)\nFinal: \(test.final.map { String($0) } ?? "Incomplete / aborted")\n\(catalog)"
    }
    private func consent() {
        guard let measurements = measurements, let credential = credential else { return }
        let sourceID = previousMeasurements?.contribution_id
        let sourceSummary = previousMeasurements?.summary ?? "Using the face scan from this visit."
        let review = sourceSummary + "\n\n\(measurements.text)\n\n" + records.map { summary($0.test) }.joined(separator: "\n\n")
        let alert = UIAlertController(title: "Review contribution", message: review + "\n\n" + AnonymousContribution.consentText, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "I agree — submit", style: .default) { [weak self] _ in
            guard let self = self, !self.submitted else { return }
            do {
                try AnonymousSubmissionStore.shared.enqueue(AnonymousContribution(measurements: measurements, tests: self.records.map { $0.test }, measurementSourceID: sourceID), credential: credential)
                self.submitted = true; self.previousMeasurements = nil; self.measurements = nil; self.records = []; self.sourceKeys = []; self.render()
            } catch { self.error(error.localizedDescription) }
        })
        alert.addAction(UIAlertAction(title: "Back", style: .cancel)); present(alert, animated: true)
    }
    @objc private func showQueue() { navigationController?.pushViewController(AnonymousQueueViewController(), animated: true) }
    @objc private func close() { confirmClear(close: true) }
    private func confirmClear(close: Bool) {
        let message = mode == .measureOnly
            ? "This clears the current measurements. Copy or share them first if you want to keep them."
            : "This clears the current scan and active participant code. Save the code first if you want to use it again. Consented submissions remain in the queue."
        let alert = UIAlertController(title: close ? "Finish?" : "Next participant?", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Clear and continue", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            self.cancelLookup(); self.previousMeasurements = nil
            self.measurements = nil; self.credential = nil; self.records = []; self.sourceKeys = []; self.reviewRecords = []; self.submitted = false
            if close { self.dismiss(animated: true) } else { self.render() }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); present(alert, animated: true)
    }
    private func qrImage(_ text: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage"); filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        let padding: CGFloat = 32 // Four white modules on each side, including in dark mode.
        let size = CGSize(width: CGFloat(image.width) + 2 * padding, height: CGFloat(image.height) + 2 * padding)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.interpolationQuality = .none
            UIImage(cgImage: image).draw(at: CGPoint(x: padding, y: padding))
        }
    }
    private func shareCSV(_ text: String) {
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("facial-measurements.csv")
            try Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtection])
            share([url]) { try? FileManager.default.removeItem(at: directory) }
        } catch { self.error("Could not prepare the CSV file.") }
    }
    private func share(_ items: [Any], completion: (() -> Void)? = nil) {
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        sheet.completionWithItemsHandler = { _, _, _, _ in completion?() }; present(sheet, animated: true)
    }
    private func error(_ text: String) {
        let alert = UIAlertController(title: "Please try again", message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
    }
}
