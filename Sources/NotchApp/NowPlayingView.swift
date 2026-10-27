import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var manager: NowPlayingManager

    var body: some View {
        if !manager.isAvailable {
            VStack {
                Spacer()
                Text(manager.adapterProblem
                     ? "Не удаётся получить данные о музыке.\nВозможно, macOS изменила доступ — нужно обновить адаптер."
                     : "Ничего не играет")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(manager.adapterProblem ? 0.6 : 0.35))
                    .multilineTextAlignment(.center)
                Spacer()
            }
        } else {
            HStack(spacing: 10) {
                artworkView
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(manager.title ?? "")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let artist = manager.artist {
                            Text(artist)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                    }

                    HStack(spacing: 16) {
                        controlButton("backward.fill", size: 11) { manager.previous() }
                        playPauseButton
                        controlButton("forward.fill", size: 11) { manager.next() }
                    }
                    .frame(maxWidth: .infinity)   // centre under the progress bar

                    ProgressBar(manager: manager)

                    HStack {
                        Text(Self.format(manager.displayedElapsed))
                        Spacer()
                        Text("-" + Self.format(max(manager.duration - manager.displayedElapsed, 0)))
                    }
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
    }

    @ViewBuilder
    private var artworkView: some View {
        if let artwork = manager.artwork {
            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.3))
                )
        }
    }

    private var playPauseButton: some View {
        Button {
            manager.togglePlayPause()
        } label: {
            Circle()
                .fill(Color.white.opacity(0.14))
                .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: manager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .offset(x: manager.isPlaying ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func controlButton(_ systemImage: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
    }

    private static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct ProgressBar: View {
    @ObservedObject var manager: NowPlayingManager
    @State private var dragFraction: Double?

    private var displayedFraction: Double {
        if let dragFraction { return dragFraction }
        guard manager.duration > 0 else { return 0 }
        return (manager.displayedElapsed / manager.duration).clamped(to: 0...1)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule().fill(Color.white.opacity(0.85))
                    .frame(width: max(geo.size.width * displayedFraction, 2))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragFraction = (value.location.x / geo.size.width).clamped(to: 0...1)
                    }
                    .onEnded { value in
                        let fraction = (value.location.x / geo.size.width).clamped(to: 0...1)
                        manager.seek(toFraction: fraction)
                        dragFraction = nil
                    }
            )
        }
        .frame(height: 4)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
