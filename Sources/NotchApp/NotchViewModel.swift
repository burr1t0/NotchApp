import Foundation

final class NotchViewModel: ObservableObject {
    @Published var isExpanded: Bool = false
    /// Small drop-down showing just a permission prompt, without the full panel.
    @Published var isPeeking: Bool = false
    /// Height of the transparent strip below the pill that the glow lives in.
    @Published var glowMargin: CGFloat = 0
    /// Physical notch width, so the peek can seat its indicators beside it.
    var notchWidth: CGFloat = 185
    /// Set by views showing a text field, so the panel becomes the key window.
    @Published var wantsKeyboard = false
    @Published var selectedTab: NotchTab = .music
}
