import SwiftUI

extension Color {
    static let marcelitoNavy = Color(red: 0.08, green: 0.17, blue: 0.29)
    static let marcelitoNavyMid = Color(red: 0.19, green: 0.29, blue: 0.41)
    static let marcelitoNavySoft = Color(red: 0.35, green: 0.43, blue: 0.53)
    static let marcelitoCream = Color(red: 0.96, green: 0.94, blue: 0.88)
    static let marcelitoCreamSoft = Color(red: 0.99, green: 0.98, blue: 0.94)
}

extension ShapeStyle where Self == Color {
    static var marcelitoNavy: Color { Color.marcelitoNavy }
    static var marcelitoNavyMid: Color { Color.marcelitoNavyMid }
    static var marcelitoNavySoft: Color { Color.marcelitoNavySoft }
    static var marcelitoCream: Color { Color.marcelitoCream }
    static var marcelitoCreamSoft: Color { Color.marcelitoCreamSoft }
}
