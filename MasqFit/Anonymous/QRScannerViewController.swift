import UIKit
import AVFoundation
import Vision

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate, UIDocumentPickerDelegate {
    var onCodes: (([String]) -> Void)?
    private let session = AVCaptureSession()
    private let cameraQueue = DispatchQueue(label: "anonymous-qr-camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private var closing = false
    private let help = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Scan QR code"; view.backgroundColor = .black
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Import image", style: .plain, target: self, action: #selector(importImage))
        help.text = "Point the rear camera at a QR code, or import a saved image from Files."
        help.textColor = .white; help.numberOfLines = 0; help.textAlignment = .center
        help.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(help)
        NSLayoutConstraint.activate([help.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            help.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            help.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)])
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self = self, !self.closing else { return }
                if allowed { self.configureCamera() }
                else { self.help.text = "Camera access is unavailable. Enable it in Settings, or import a QR image." }
            }
        }
    }
    private func configureCamera() {
        cameraQueue.async { [weak self] in
            guard let self = self,
                  let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) else { return }
            self.session.beginConfiguration(); self.session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard self.session.canAddOutput(output) else { self.session.commitConfiguration(); return }
            self.session.addOutput(output); output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]; self.session.commitConfiguration()
            DispatchQueue.main.async {
                guard !self.closing else { return }
                let preview = AVCaptureVideoPreviewLayer(session: self.session)
                preview.videoGravity = .resizeAspectFill; preview.frame = self.view.bounds
                self.view.layer.insertSublayer(preview, at: 0); self.preview = preview
                self.cameraQueue.async { self.session.startRunning() }
            }
        }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true { stop() }
    }
    private func stop() { closing = true; cameraQueue.async { self.session.stopRunning() } }
    @objc private func close() { stop(); dismiss(animated: true) }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        let codes = objects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
        if !codes.isEmpty { finish(codes) }
    }
    private func finish(_ codes: [String]) {
        guard !closing, presentedViewController == nil else { return }
        stop(); dismiss(animated: true) { self.onCodes?(codes) }
    }
    @objc private func importImage() {
        cameraQueue.async { self.session.stopRunning() }
        let picker = UIDocumentPickerViewController(documentTypes: ["public.image"], in: .open)
        picker.delegate = self; present(picker, animated: true)
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        cameraQueue.async { self.session.startRunning() }
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        cameraQueue.async {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 20_000_000 else { throw StoreError.message("Choose an image smaller than 20 MB.") }
                let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
                try VNImageRequestHandler(url: url).perform([request])
                let codes = (request.results ?? []).compactMap { $0.payloadStringValue }
                DispatchQueue.main.async {
                    let deliver = {
                        if codes.isEmpty {
                            self.help.text = "No QR code found. Try a clearer image."
                            self.cameraQueue.async { self.session.startRunning() }
                        }
                        else { self.finish(codes) }
                    }
                    if self.presentedViewController != nil { self.dismiss(animated: true, completion: deliver) }
                    else { deliver() }
                }
            } catch { DispatchQueue.main.async { self.help.text = "Could not read that image. Try a smaller, clearer image."; self.cameraQueue.async { self.session.startRunning() } } }
        }
    }
}
