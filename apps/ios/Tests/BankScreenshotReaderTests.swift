import Foundation
import XCTest
@testable import Marcelito

final class BankScreenshotReaderTests: XCTestCase {
    private func decimal(_ value: String) -> Decimal {
        Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))!
    }

    private var capturedAt: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Mexico_City")!
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 12))!
    }

    func testReadsBBVAMobileRowsWithDisplayedSigns() throws {
        let result = try BankScreenshotReader.parseTextForTesting([
            "Movimientos BBVA",
            "7 agosto 2026",
            "Iva rep tarj tit $ -9.63",
            "Movimiento BBVA",
            "Comision cajero red $ -60.23",
            "Movimiento BBVA",
            "5 agosto 2026",
            "Spei recibido santander $ 4,500.00",
            "Transferencia interbancaria recibida",
        ], source: .bbva, capturedAt: capturedAt)

        XCTAssertEqual(result.movements.count, 3)
        XCTAssertEqual(result.movements.map(\.displayedAmount), [decimal("-9.63"), decimal("-60.23"), decimal("4500")])
        XCTAssertEqual(result.movements[2].title, "Spei recibido santander")
    }

    func testBBVACounterpartyNameDoesNotReclassifyScreenshot() throws {
        let source = try BankScreenshotReader.resolveSource(
            in: "Movimientos BBVA\nSPEI recibido Santander\nTransferencia interbancaria recibida",
            hintedSource: .bbva
        )

        XCTAssertEqual(source, .bbva)
    }

    func testStrongAppHeaderStillRejectsARealMixedBankBatch() {
        XCTAssertThrowsError(
            try BankScreenshotReader.resolveSource(
                in: "The Platinum Credit Card American Express\nVIVAAEROBUS $3,465.51",
                hintedSource: .bbva
            )
        ) { error in
            XCTAssertEqual(error as? BankScreenshotImportError, .mixedSources)
        }
    }

    func testReadsWrappedSantanderRows() throws {
        let result = try BankScreenshotReader.parseTextForTesting([
            "SUPER NOMINA 56**7079",
            "martes 08 de septiembre 2026",
            "Retiro sin tarjeta -1,300.00 MXN",
            "TRANSFERENCIA A HERMINIO MI...",
            "-40.00 MXN",
            "viernes 04 de septiembre 2026",
            "2468293 RFC ACE810901298 0, -12,000.00 MXN",
        ], source: .santander, capturedAt: capturedAt)

        XCTAssertEqual(result.movements.count, 3)
        XCTAssertEqual(result.movements[1].title, "TRANSFERENCIA A HERMINIO MI...")
        XCTAssertEqual(result.movements[1].displayedAmount, -40)
        XCTAssertEqual(result.movements[2].displayedAmount, -12_000)
    }

    func testReadsAmexPendingRowsAndNormalizesCardSigns() throws {
        let result = try BankScreenshotReader.parseTextForTesting([
            "The Platinum Credit Card American Express ••••51003",
            "8 sep",
            "TACOS EL GUERO",
            "$405.00",
            "Pendiente",
            "7 ELEVEN T957 LA SALLE $69.50 Pendiente",
            "7 sep",
            "VIVAAEROBUS $3,465.51",
            "2 sep",
            "GRACIAS POR SU PAGO EN LINEA -$12,000.00",
        ], source: .amex, capturedAt: capturedAt)

        XCTAssertEqual(result.movements.count, 4)
        XCTAssertTrue(result.movements[0].pending)
        XCTAssertTrue(result.movements[1].pending)
        XCTAssertEqual(result.movements[0].normalizedAmount, -405)
        XCTAssertEqual(result.movements[2].normalizedAmount, decimal("-3465.51"))
        XCTAssertEqual(result.movements[3].normalizedAmount, 12_000)
    }

    func testAdvertisementAmountIsNotImported() throws {
        let result = try BankScreenshotReader.parseTextForTesting([
            "5 sep",
            "TOKS MUNDO E TLALNEPANTLA $137.50",
            "$6,000 M.N. POR REFERIR",
            "Podrás recibir $6,000 M.N. en cashback por cada amigo",
            "4 sep",
            "UBER TRIP HTTPS://HELP.UB $193.34",
        ], source: .amex, capturedAt: capturedAt)

        XCTAssertEqual(result.movements.count, 2)
        XCTAssertFalse(result.movements.contains { abs($0.displayedAmount) == 6_000 })
    }

    func testOverlappingCaptureKeepsEvidenceButOnlyOneCanonicalObservation() throws {
        let store = FinanceStore()
        store.clearLocalData()
        defer { store.clearLocalData() }
        let date = capturedAt

        func result(fingerprint: String, byte: UInt8) -> BankScreenshotImportResult {
            let movement = BankScreenshotMovement(
                date: date,
                title: "VIVAAEROBUS",
                displayedAmount: 3_465.51,
                normalizedAmount: -3_465.51,
                pending: false,
                confidence: 0.95,
                imageFingerprint: fingerprint,
                evidence: MovementExtractionEvidence(method: "screenshot-vision", confidence: 0.95)
            )
            return BankScreenshotImportResult(
                source: .amex,
                accountKey: "amex:1003",
                importedAt: date,
                inputs: [BankScreenshotInput(data: Data([byte]), fileName: "fixture")],
                imageFingerprints: [fingerprint],
                movements: [movement],
                warnings: []
            )
        }

        let first = try store.saveBankScreenshotImport(result(fingerprint: "image-a", byte: 1))
        let overlap = try store.saveBankScreenshotImport(result(fingerprint: "image-b", byte: 2))

        XCTAssertEqual(first.movementCount, 1)
        XCTAssertEqual(overlap.movementCount, 0)
        XCTAssertEqual(overlap.duplicateCount, 1)
        XCTAssertEqual(store.canonicalScreenshotMovements.count, 1)
    }
}
