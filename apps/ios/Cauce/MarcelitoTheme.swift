import SwiftUI

extension Color {
    static let marcelitoNavy = Color(red: 0.08, green: 0.17, blue: 0.29)
    static let marcelitoNavyDeep = Color(red: 0.045, green: 0.105, blue: 0.19)
    static let marcelitoNavyMid = Color(red: 0.19, green: 0.29, blue: 0.41)
    static let marcelitoNavySoft = Color(red: 0.35, green: 0.43, blue: 0.53)
    static let marcelitoCream = Color(red: 0.95, green: 0.96, blue: 0.97)
    static let marcelitoCreamSoft = Color(red: 0.985, green: 0.99, blue: 0.995)
    static let marcelitoCreamTint = Color(red: 0.90, green: 0.93, blue: 0.97)
    static let marcelitoLine = Color(red: 0.82, green: 0.86, blue: 0.91)
    static let marcelitoAmber = Color(red: 0.72, green: 0.42, blue: 0.12)
    static let marcelitoViolet = Color(red: 0.38, green: 0.24, blue: 0.52)
    static let marcelitoSuccess = Color(red: 0.16, green: 0.43, blue: 0.31)
    static let marcelitoDanger = Color(red: 0.67, green: 0.20, blue: 0.17)
}

extension ShapeStyle where Self == Color {
    static var marcelitoNavy: Color { Color.marcelitoNavy }
    static var marcelitoNavyDeep: Color { Color.marcelitoNavyDeep }
    static var marcelitoNavyMid: Color { Color.marcelitoNavyMid }
    static var marcelitoNavySoft: Color { Color.marcelitoNavySoft }
    static var marcelitoCream: Color { Color.marcelitoCream }
    static var marcelitoCreamSoft: Color { Color.marcelitoCreamSoft }
    static var marcelitoCreamTint: Color { Color.marcelitoCreamTint }
    static var marcelitoLine: Color { Color.marcelitoLine }
    static var marcelitoAmber: Color { Color.marcelitoAmber }
    static var marcelitoViolet: Color { Color.marcelitoViolet }
    static var marcelitoSuccess: Color { Color.marcelitoSuccess }
    static var marcelitoDanger: Color { Color.marcelitoDanger }
}

struct MarcelitoAmbientBackground: View {
    var body: some View {
        ZStack {
            Color.marcelitoCream
            RadialGradient(
                colors: [Color.marcelitoNavySoft.opacity(0.18), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 330
            )
            RadialGradient(
                colors: [Color.marcelitoNavyMid.opacity(0.10), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 300
            )
        }
        .ignoresSafeArea()
    }
}

struct MarcelitoCardModifier: ViewModifier {
    var fill: Color = .marcelitoCreamSoft
    var radius: CGFloat = 24
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(fill.opacity(0.68))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .stroke(Color.white.opacity(0.78), lineWidth: 1)
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: Color.marcelitoNavy.opacity(0.075), radius: 18, x: 0, y: 8)
    }
}

extension View {
    func marcelitoCard(
        fill: Color = .marcelitoCreamSoft,
        radius: CGFloat = 24,
        padding: CGFloat = 18
    ) -> some View {
        modifier(MarcelitoCardModifier(fill: fill, radius: radius, padding: padding))
    }
}
