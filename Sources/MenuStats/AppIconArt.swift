#if DEBUG
import SwiftUI

/// The app icon artwork, drawn at 1024×1024 on Apple's icon grid (an 824 pt rounded square,
/// centred). `MenuStats --snapshot <dir> --icon` renders it; `make-icon.sh` turns that into
/// Resources/AppIcon.icns.
struct AppIconArt: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.17, green: 0.19, blue: 0.42),
                                              Color(red: 0.05, green: 0.06, blue: 0.16)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    // A soft top highlight gives the tile some depth.
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.02)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 6)
                )
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)

            ring(diameter: 560, lineWidth: 62, fraction: 0.72,
                 colors: [Color(red: 0.25, green: 0.85, blue: 1.0), Color(red: 0.2, green: 0.45, blue: 1.0)])
            ring(diameter: 396, lineWidth: 62, fraction: 0.48,
                 colors: [Color(red: 1.0, green: 0.42, blue: 0.75), Color(red: 0.62, green: 0.35, blue: 1.0)])

            // A tiny bar chart in the middle, like the per-core bars.
            HStack(alignment: .bottom, spacing: 20) {
                bar(height: 70)
                bar(height: 130)
                bar(height: 100)
            }
            .frame(height: 130, alignment: .bottom)
        }
        .frame(width: 1024, height: 1024)
    }

    private func ring(diameter: CGFloat, lineWidth: CGFloat, fraction: Double, colors: [Color]) -> some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.10), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(AngularGradient(colors: colors + [colors[0]], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * fraction)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: colors[0].opacity(0.55), radius: 18)
        }
        .frame(width: diameter, height: diameter)
    }

    private func bar(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(LinearGradient(colors: [.white, .white.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            .frame(width: 34, height: height)
    }
}
#endif
