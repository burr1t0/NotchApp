import SwiftUI

enum NotchTab: String, CaseIterable, Identifiable {
    case music = "Музыка"
    case claude = "Claude"
    case screenshots = "Файлы"
    case clipboard = "Буфер"
    case translate = "Перевод"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .music: return "music.note"
        case .claude: return "sparkles"
        case .screenshots: return "tray.full"
        case .clipboard: return "doc.on.clipboard"
        case .translate: return "character.bubble"
        }
    }
}

struct ContentView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var clipboardManager: ClipboardManager
    @ObservedObject var screenshotWatcher: ScreenshotWatcher
    @ObservedObject var nowPlayingManager: NowPlayingManager
    let audioMonitor: AudioLevelMonitor
    @ObservedObject var translatorManager: TranslatorManager
    @ObservedObject var claudeMonitor: ClaudeMonitor

    private var showsPill: Bool { nowPlayingManager.isAvailable || claudeMonitor.indicator != nil }

    private var isOpen: Bool { viewModel.isExpanded || viewModel.isPeeking }
    private var topCornerRadius: CGFloat { isOpen ? 16 : 8 }
    private var bottomCornerRadius: CGFloat { isOpen ? 24 : 10 }

    /// Must match NotchWindowController.musicIndicatorWidth — that value
    /// sizes the actual collapsed window frame, this one lays out content
    /// to fill it.
    private let musicIndicatorWidth: CGFloat = 42

    /// Transparent strip the window gets below the pill while Claude waits on
    /// you; the glow is drawn into it (see NotchWindowController.setGlow).
    private var glowMargin: CGFloat { viewModel.glowMargin }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                if glowMargin > 0 {
                    glow(width: geo.size.width, pillHeight: geo.size.height - glowMargin)
                }
                pill
                    .frame(height: max(geo.size.height - glowMargin, 0))
            }
        }
    }

    /// Soft orange light spilling out under the bottom edge, strongest in
    /// the middle and fading out sideways.
    private func glow(width: CGFloat, pillHeight: CGFloat) -> some View {
        Ellipse()
            .fill(Color.claudeOrange.opacity(0.75))
            .frame(width: width * 0.8, height: glowMargin * 1.1)
            .blur(radius: 9)
            .position(x: width / 2, y: pillHeight - 1)
            .allowsHitTesting(false)
    }

    private var pill: some View {
        ZStack(alignment: .topLeading) {
            Color.black

            if viewModel.isExpanded {
                expandedContent
            } else if viewModel.isPeeking, let request = claudeMonitor.pending.first {
                peekContent(request)
            } else if showsPill {
                collapsedMusicIndicator
            }
        }
        .clipShape(NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius))
        // Deliberately NOT animated here. The window frame resize
        // (NotchWindowController.animate) is a separate, AppKit/Core
        // Animation-driven timeline from anything SwiftUI's own
        // `.animation()` would run — even with matched durations they
        // don't share a clock, so the content visibly keeps settling
        // after the window has already reached its final size and
        // position. Flipping opacity instantly makes the window resize
        // the *only* source of visible motion, which is what actually
        // stays pinned to the top edge throughout.
        .opacity(isOpen || showsPill ? 1 : 0)
    }

    /// Small album-art + equalizer indicator either side of the physical
    /// notch while collapsed, mirroring the reference app's
    /// "MusicLiveActivity" — the gap between them lines up with the notch
    /// itself, which NotchWindowController widens the window to leave room
    /// for.
    private var collapsedMusicIndicator: some View { musicIndicator(showingStatus: true) }

    /// `showingStatus: false` keeps the equalizer where the Claude badge
    /// would replace it (used while the drop-down already shows the prompt).
    private func musicIndicator(showingStatus: Bool) -> some View {
        HStack(spacing: 0) {
            Group {
                if nowPlayingManager.isAvailable {
                    albumArtThumb
                } else {
                    ClaudeBot()
                        .foregroundStyle(Color.claudeOrange)
                        .frame(width: 22, height: 14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: musicIndicatorWidth)

            Spacer(minLength: 0)

            // Claude wants you (or just finished) → its status takes the
            // equalizer's slot until it's dealt with / a few seconds pass.
            Group {
                if let indicator = claudeMonitor.indicator, showingStatus || !nowPlayingManager.isAvailable {
                    ClaudeStatusBadge(indicator: indicator)
                } else {
                    EqualizerBars(isPlaying: nowPlayingManager.isPlaying, monitor: audioMonitor)
                }
            }
            .frame(width: musicIndicatorWidth)
        }
    }

    private var albumArtThumb: some View {
        Group {
            if let artwork = nowPlayingManager.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Clears the physical camera housing, which visually swallows the top
    /// strip of the panel regardless of what we draw there.
    private let notchClearance: CGFloat = 34

    private var expandedContent: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: notchClearance)

            // NotchShape's concave top corners keep the left/right edges
            // inset by topCornerRadius for nearly the panel's whole height
            // (it's not just a corner nibble) — content must stay clear of
            // that band on both sides or it renders into the clipped area.
            HStack(spacing: 0) {
                sidebar
                    .padding(.trailing, 4)

                Divider()
                    .overlay(Color.white.opacity(0.08))

                Group {
                    switch viewModel.selectedTab {
                    case .music:
                        NowPlayingView(manager: nowPlayingManager)
                    case .claude:
                        ClaudeView(monitor: claudeMonitor, setKeyboard: { viewModel.wantsKeyboard = $0 })
                    case .screenshots:
                        ScreenshotsView(watcher: screenshotWatcher)
                    case .clipboard:
                        ClipboardView(manager: clipboardManager)
                    case .translate:
                        TranslatorView(manager: translatorManager)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
            }
            .padding(.horizontal, topCornerRadius)
            .padding(.bottom, 8)
        }
    }

    /// Just the permission prompt, dropped a little below the notch.
    private func peekContent(_ request: ClaudePermissionRequest) -> some View {
        VStack(spacing: 0) {
            // Same album art / equalizer / status slots as the collapsed
            // pill, either side of the notch, so music doesn't vanish while
            // the prompt is down.
            Group {
                if showsPill {
                    musicIndicator(showingStatus: false)
                        .frame(width: viewModel.notchWidth + musicIndicatorWidth * 2)
                } else {
                    Color.clear
                }
            }
            .frame(height: notchClearance - 1)
            PermissionCard(monitor: claudeMonitor, request: request,
                           more: claudeMonitor.pending.count - 1, compact: true)
                .padding(.horizontal, topCornerRadius + 6)
                .padding(.bottom, 12)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 3) {
            ForEach(NotchTab.allCases) { tab in
                Button {
                    viewModel.selectedTab = tab
                } label: {
                    Group {
                        if tab == .claude {
                            ClaudeBot().frame(width: 19, height: 12)
                        } else {
                            Image(systemName: tab.systemImage)
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                        .frame(width: 28, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(viewModel.selectedTab == tab ? Color.white.opacity(0.16) : Color.clear)
                        )
                        .foregroundStyle(viewModel.selectedTab == tab ? .white : .white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .help(tab.rawValue)
                .onHover { isHovering in
                    if isHovering { viewModel.selectedTab = tab }
                }
            }
            Spacer()
        }
        .frame(width: 40)
    }
}
