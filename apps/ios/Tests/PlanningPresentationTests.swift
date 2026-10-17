import XCTest
import SwiftUI
@testable import Marcelito

@MainActor final class PlanningPresentationTests: XCTestCase {
    func testHomeAvailableCardRendersAllSpendingOnIPhoneWidths() throws {
        let original = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("marcelito.") }
        let name = "marcelito.presentation.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        let store = FinanceStore(); store.clearLocalData()
        defer {
            store.clearLocalData()
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("marcelito.") { UserDefaults.standard.removeObject(forKey: key) }
            for (key, value) in original { UserDefaults.standard.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: name)
        }
        let planning = FinancialPlanningStore(defaults: defaults)
        planning.state.incomeAmount = 10000
        store.movements = [
            Movement(date: .now, title: "Gasto ordinario de prueba", account: "BBVA", category: "Tiendita", amount: -1000, flow: .expense, kind: .purchase),
            Movement(date: .now, title: "Extraordinario de prueba", account: "BBVA", category: "Viajes", amount: -3000, flow: .expense, kind: .purchase, travelRelated: true)
        ]
        XCTAssertEqual(planning.snapshot(store, month: .now).remaining, 6000)
        for width in [CGFloat(320), CGFloat(393), CGFloat(440)] {
            let card = HomeMonthlyPlanCard(upload: {}, showLatest: { _ in })
                .environment(store).environment(planning).environment(\.locale, Locale(identifier: "es_MX"))
                .padding(16).frame(width: width).background(Color.marcelitoCreamSoft)
            let renderer = ImageRenderer(content: card)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertGreaterThan(image.size.height, 100)
            XCTAssertEqual(image.size.width, width)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Inicio-disponible-\(Int(width))"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
