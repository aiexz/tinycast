import Combine
import Foundation

/// The live level behind the slider and the HUD's bar. Published so a repeated command refreshes a
/// HUD already on screen instead of rebuilding it; the arithmetic lives in `VolumeLevel`.
final class VolumeState: ObservableObject {
    @Published var level: Double
    @Published var muted: Bool

    init(level: Double, muted: Bool = false) {
        self.level = level
        self.muted = muted
    }
}
