import XCTest
@testable import Marcelito

final class FinanceBackupTests: XCTestCase {
    private func isolated(_ body: (UserDefaults, URL) throws -> Void) throws {
        let name = "marcelito.backup.native.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("ImportedStatements"), withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        try body(defaults, directory)
    }
    func testEncryptedRoundTripRestoresRulesPlansAndExactDocuments() throws {
        try isolated { defaults, directory in
            let planning = FinancialPlanningStore(defaults: defaults)
            let goal = SavingsGoal(name: "Meta sintética", target: 10000, saved: 2000, monthlyContribution: 500)
            XCTAssertTrue(planning.saveGoal(goal))
            defaults.set(["oxxo": "Tiendita"], forKey: "marcelito.categoryRules.v1")
            defaults.set("excluded-synthetic-token", forKey: "marcelito.auth.token")
            let pdf = Data("%PDF-fixture-synthetic".utf8)
            let file = directory.appendingPathComponent("ImportedStatements/fixture.pdf")
            try pdf.write(to: file)
            let payload = try FinanceBackup.capture(defaults: defaults, directory: directory)
            XCTAssertNil(try FinanceBackup.validate(payload)["marcelito.auth.token"])
            let encrypted = try FinanceBackup.encrypt(payload, password: "synthetic-backup-password")
            let recovered = try FinanceBackup.decrypt(encrypted, password: "synthetic-backup-password")
            defaults.set(["oxxo": "Otra"], forKey: "marcelito.categoryRules.v1")
            try FinanceBackup.restore(recovered, defaults: defaults, directory: directory)
            XCTAssertEqual(defaults.dictionary(forKey: "marcelito.categoryRules.v1") as? [String: String], ["oxxo": "Tiendita"])
            XCTAssertEqual(FinancialPlanningStore(defaults: defaults).state.goals.first?.saved, 2000)
            XCTAssertEqual(try Data(contentsOf: file), pdf)
            XCTAssertEqual(defaults.string(forKey: "marcelito.auth.token"), "excluded-synthetic-token")
        }
    }
    func testWrongPasswordAndInvalidArchiveNeverMutateExistingData() throws {
        try isolated { defaults, directory in
            defaults.set(["oxxo": "Tiendita"], forKey: "marcelito.categoryRules.v1")
            let payload = try FinanceBackup.capture(defaults: defaults, directory: directory)
            let encrypted = try FinanceBackup.encrypt(payload, password: "synthetic-backup-password")
            XCTAssertThrowsError(try FinanceBackup.decrypt(encrypted, password: "different-password"))
            var tampered = encrypted; tampered[tampered.count / 2] ^= 1
            XCTAssertThrowsError(try FinanceBackup.decrypt(tampered, password: "synthetic-backup-password"))
            let bad = FinanceBackupPayload(schema: 1, createdAt: .now, preferences: payload.preferences, files: ["ImportedStatements/../outside.pdf": Data()])
            XCTAssertThrowsError(try FinanceBackup.restore(bad, defaults: defaults, directory: directory))
            XCTAssertEqual(defaults.dictionary(forKey: "marcelito.categoryRules.v1") as? [String: String], ["oxxo": "Tiendita"])
        }
    }
    func testInterruptedRestoreRecoversPriorFinancialStateBeforeLoadingStore() throws {
        try isolated { defaults, directory in
            defaults.set(["oxxo": "Tiendita"], forKey: "marcelito.categoryRules.v1")
            let payload = try FinanceBackup.capture(defaults: defaults, directory: directory)
            let journal = directory.appendingPathComponent("marcelito-restore-rollback.json")
            try JSONEncoder().encode(payload).write(to: journal, options: FinanceBackup.fileOptions)
            defaults.set(["oxxo": "Interrumpido"], forKey: "marcelito.categoryRules.v1")
            try FinanceBackup.recoverInterruptedRestore(defaults: defaults, directory: directory)
            XCTAssertEqual(defaults.dictionary(forKey: "marcelito.categoryRules.v1") as? [String: String], ["oxxo": "Tiendita"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        }
    }
}
