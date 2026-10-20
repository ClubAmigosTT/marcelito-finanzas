import XCTest
@testable import Marcelito

final class ExpenseCategoryRulesTests: XCTestCase {
    func testProcessorPrefixesAndGluedStoreNumbersReachTheMerchant() {
        XCTAssertEqual(FinanceStore.categoryForTesting("MERCADOPAGO*CANVA123456 CIUDAD EJEMPLO"), "Software y suscripciones")
        XCTAssertEqual(FinanceStore.categoryForTesting("BILLPOCKET*LA TORTA EJEMPLO"), "Restaurantes y bares")
        XCTAssertEqual(FinanceStore.categoryForTesting("TST* TAQUERIA EJEMPLO NEW YORK"), "Restaurantes y bares")
        XCTAssertEqual(FinanceStore.categoryForTesting("7ELEVEN SUCURSAL"), "Tiendita")
        XCTAssertEqual(FinanceStore.categoryForTesting("OXXOEJEMPLO"), "Tiendita")
    }

    func testPluralsAndStemsMatch() {
        XCTAssertEqual(FinanceStore.categoryForTesting("LOS TACOS DEL EJEMPLO"), "Restaurantes y bares")
        XCTAssertEqual(FinanceStore.categoryForTesting("PELUQ EL EJEMPLO BENITO JUAREZ"), "Cuidado personal")
        XCTAssertEqual(FinanceStore.categoryForTesting("EST CENTRO EJEMPLO 0001"), "Transporte")
        XCTAssertEqual(FinanceStore.categoryForTesting("ESTAC EJEMPLO ESTACIONAMIEN"), "Transporte")
    }

    func testCashAndThirdPartyTransfersGetTheirOwnBuckets() {
        XCTAssertEqual(FinanceStore.categoryForTesting("RETIRO EFEC SIN TARJETA EN ATM"), "Retiros de efectivo")
        XCTAssertEqual(FinanceStore.categoryForTesting("PAGO CUENTA DE TERCERO"), "Transferencias a terceros")
        XCTAssertEqual(FinanceStore.categoryForTesting("PAGO TRANSF RAPIDA SPEI TRANSFERENCIA A EJEMPLO"), "Transferencias a terceros")
        XCTAssertEqual(FinanceStore.categoryForTesting("COMISION RETIRO CAJERO"), "Comisiones y finanzas")
    }

    func testUnknownProcessorMerchantStaysForReview() {
        XCTAssertEqual(FinanceStore.categoryForTesting("MERCADOPAGO*NOMBREDESCONOCIDO"), "Otros / Por revisar")
    }

    func testEveryRuleCategoryIsSelectableAndKnownToTheAI() {
        for title in ["RETIRO EFEC SIN TARJETA", "PAGO CUENTA DE TERCERO", "PELUQ EJEMPLO"] {
            XCTAssertTrue(ExpenseAIClassifier.allowedCategories.contains(FinanceStore.categoryForTesting(title)))
        }
    }
}
