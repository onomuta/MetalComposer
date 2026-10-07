import MetalKit
import MetalComposerKit
import UIKit

/// An external screen (HDMI adapter, AirPlay to an Apple TV): while one is connected, the playing
/// composition renders there at the screen's size and refresh rate, and the device shows a preview
/// with the controls. With nothing playing, the screen stays black.
final class ExternalDisplay: NSObject, ObservableObject, MTKViewDelegate {
    static let shared = ExternalDisplay()

    /// The screen's size in pixels; nil when none is connected.
    @Published private(set) var size: CGSize?
    /// What the screen shows. The player sets it while it's open.
    weak var playback: Playback?

    var isConnected: Bool { size != nil }

    /// Makes the window that fills the external screen.
    func connect(_ scene: UIWindowScene) -> UIWindow? {
        guard let engine = Engine.shared else { return nil }
        let window = UIWindow(windowScene: scene)
        let view = MTKView(frame: window.bounds, device: engine.device)
        view.colorPixelFormat = MetalComposerEngine.pixelFormat
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // The composition's frame is copied in, so the drawable can't be framebuffer-only.
        view.framebufferOnly = false
        view.contentScaleFactor = scene.screen.scale
        view.preferredFramesPerSecond = scene.screen.maximumFramesPerSecond
        view.delegate = self
        let controller = UIViewController()
        controller.view = view
        window.rootViewController = controller
        window.isHidden = false
        size = view.drawableSize
        return window
    }

    func disconnect() {
        size = nil
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if isConnected, size.width > 0, size.height > 0 { self.size = size }
    }

    func draw(in view: MTKView) {
        if let playback {
            playback.drawExternal(in: view)
        } else if let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let commandBuffer = Engine.queue?.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

/// Scene delegate for the external screen's (non-interactive) scene.
final class ExternalSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        window = ExternalDisplay.shared.connect(scene)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        ExternalDisplay.shared.disconnect()
        window = nil
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        if session.role == .windowExternalDisplayNonInteractive {
            configuration.delegateClass = ExternalSceneDelegate.self
        }
        return configuration
    }
}
