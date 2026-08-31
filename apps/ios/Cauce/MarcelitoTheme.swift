import SwiftUI

extension Color {
    static let marcelitoNavy = Color(red: 0.08, green: 0.17, blue: 0.29)
    static let marcelitoNavyDeep = Color(red: 0.045, green: 0.105, blue: 0.19)
    static let marcelitoNavyMid = Color(red: 0.19, green: 0.29, blue: 0.41)
    static let marcelitoNavySoft = Color(red: 0.35, green: 0.43, blue: 0.53)
    static let marcelitoCream = Color(red: 0.96, green: 0.94, blue: 0.88)
    static let marcelitoCreamSoft = Color(red: 0.99, green: 0.98, blue: 0.94)
    static let marcelitoCreamTint = Color(red: 0.925, green: 0.905, blue: 0.84)
    static let marcelitoLine = Color(red: 0.84, green: 0.82, blue: 0.75)
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

struct MarcelitoCardModifier: ViewModifier {
    var fill: Color = .marcelitoCreamSoft
    var radius: CGFloat = 16
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func marcelitoCard(
        fill: Color = .marcelitoCreamSoft,
        radius: CGFloat = 16,
        padding: CGFloat = 18
    ) -> some View {
        modifier(MarcelitoCardModifier(fill: fill, radius: radius, padding: padding))
    }
}
