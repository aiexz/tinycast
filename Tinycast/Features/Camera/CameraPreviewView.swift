import SwiftUI
import AVFoundation
import AppKit

enum CameraState {
    case requesting
    case denied
    case unavailable
    case failed
    case running
}

@MainActor
final class CameraPreviewController: ObservableObject {
    private final class SessionBox: @unchecked Sendable {
        let value = AVCaptureSession()
    }

    @Published var state: CameraState = .requesting
    private let sessionBox = SessionBox()
    var session: AVCaptureSession { sessionBox.value }
    private var isActive = false

    func start() {
        isActive = true
        
        Task {
            let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
            
            switch authStatus {
            case .notDetermined:
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                if granted {
                    await setupAndStartSession()
                } else {
                    self.state = .denied
                }
            case .restricted, .denied:
                self.state = .denied
            case .authorized:
                await setupAndStartSession()
            @unknown default:
                self.state = .failed
            }
        }
    }
    
    func stop() {
        isActive = false
        let sessionBox = sessionBox
        Task.detached { sessionBox.value.stopRunning() }
    }
    
    private func setupAndStartSession() async {
        guard isActive else { return }
        
        let sessionBox = sessionBox
        let success = await Task.detached { [sessionBox] () -> Bool in
            let session = sessionBox.value
            session.beginConfiguration()
            
            guard let videoDevice = AVCaptureDevice.default(for: .video) else {
                session.commitConfiguration()
                return false
            }
            
            do {
                let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
                
                if session.canAddInput(videoDeviceInput) {
                    session.addInput(videoDeviceInput)
                } else {
                    session.commitConfiguration()
                    return false
                }
                
                session.commitConfiguration()
                session.startRunning()
                return true
            } catch {
                session.commitConfiguration()
                return false
            }
        }.value
        
        if success, isActive {
            self.state = .running
        } else if success {
            let sessionBox = sessionBox
            Task.detached { sessionBox.value.stopRunning() }
        } else {
            self.state = .unavailable
        }
    }
    
    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct VideoPreviewLayerWrapper: NSViewRepresentable {
    let session: AVCaptureSession
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        
        // Setup initial layout properly using Auto Layout for layer sizing, but since it's a layer we update on bounds change.
        // Doing this in updateNSView when bounds change is tricky in pure NSView, so we create a simple NSView subclass.
        let localView = PreviewLayerView()
        localView.wantsLayer = true
        localView.layer?.addSublayer(previewLayer)
        
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        
        return localView
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        if let layer = nsView.layer, let previewLayer = layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
            previewLayer.session = session
            
            if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }
    }
}

final class PreviewLayerView: NSView {
    override func layout() {
        super.layout()
        if let layer = self.layer, let previewLayer = layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
            previewLayer.frame = layer.bounds
        }
    }
}

public struct CameraPreviewView: View {
    @StateObject private var controller = CameraPreviewController()
    
    public init() {}
    
    public var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            
            switch controller.state {
            case .requesting:
                ProgressView()
                    .controlSize(.small)
            case .running:
                VideoPreviewLayerWrapper(session: controller.session)
                    .edgesIgnoringSafeArea(.all)
            case .denied:
                VStack(spacing: 12) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                    Text("Camera Access Denied")
                        .font(.headline)
                    Text("Tinycast needs permission to show the camera preview.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Open System Settings") {
                        controller.openSettings()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                }
            case .unavailable:
                VStack(spacing: 8) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                    Text("Camera Unavailable")
                        .font(.headline)
                }
            case .failed:
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundColor(.red)
                    Text("Camera Setup Failed")
                        .font(.headline)
                }
            }
        }
        .onAppear {
            controller.start()
        }
        .onDisappear {
            controller.stop()
        }
    }
}
