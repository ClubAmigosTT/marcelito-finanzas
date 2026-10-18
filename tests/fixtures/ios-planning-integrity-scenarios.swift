// Executed against the production planning, history and backup implementations
// with a synthetic FinanceStore adapter. No on-device book or PDFs are touched.
func expect(_ value: @autoclosure () -> Bool, _ name: String) { guard value() else { fatalError(name) }; print("PASS:", name); fflush(stdout) }
let calendar = Calendar.current
func day(_ month: Int, _ day: Int = 1) -> Date { calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))! }
let suite = "marcelito.integrity.fixture.\(UUID())"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let planning = FinancialPlanningStore(defaults: defaults)
let store = FinanceStore()
func charge(_ value: Decimal, extra: Bool = false) -> Movement {
    var row = Movement(date: day(9,15), title: "Cargo sintético", account: "BBVA", category: "Compras", amount: -value)
    row.travelRelated = extra; return row
}
planning.state.incomeAmount = 10000
store.movements = [charge(1000),charge(3000,extra:true)]
expect(planning.total(store,period:.month(day(9))) == 4000, "registered spending includes extraordinary")
expect(planning.snapshot(store,month:day(9),now:day(9,17)).remaining == 6000, "remaining deducts extraordinary without rewriting source")
let shared = charge(2000)
store.movements = [shared]
planning.setLabel(PersonalExpenseLabel(sharedPerson:"Amiga",sharedAmount:1000),for:shared)
expect(planning.snapshot(store,month:day(9),now:day(9,17)).remaining == 8000, "uncollected shared money stays deducted")
var label = planning.label(for:shared);label.collectedAmount=1000;planning.setLabel(label,for:shared)
expect(planning.snapshot(store,month:day(9),now:day(9,17)).remaining == 8000, "collection checkbox does not fabricate bank income")
var plan = planning.plan(for:day(9));plan.spendingLimit=5000;plan.savingsTarget=1000;planning.setPlan(plan,for:day(9))
expect(planning.snapshot(store,month:day(9),now:day(9,17)).remaining == 3000,"shared plan applies spending cap after savings reserve")
plan.spendingLimit=20000;planning.setPlan(plan,for:day(9))
expect(planning.snapshot(store,month:day(9),now:day(9,17)).remaining == 7000,"cap never exceeds actual planned income allowance")
expect(planning.setIncomeSources([PlanningIncomeSource(name:"Nuevo",amount:12000,cadence:"Mensual")],effectiveFrom:day(10)),"income revision saved")
expect(planning.monthlyIncome(for:day(9)) == 10000 && planning.monthlyIncome(for:day(10)) == 12000,"new salary does not rewrite prior months")
let restored = FinancialPlanningStore(defaults:defaults)
expect(restored.monthlyIncome(for:day(9)) == 10000 && restored.monthlyIncome(for:day(10)) == 12000,"income effective dates survive reload")
let oldKey="marcelito.monthlyPlan.2026.8"
defaults.set("5000",forKey:oldKey+".budget");defaults.set("1000",forKey:oldKey+".target")
let migrated = FinancialPlanningStore(defaults:defaults)
expect(migrated.plan(for:day(8)).spendingLimit == 5000 && migrated.plan(for:day(8)).savingsTarget == 1000,"legacy plan migrates into shared monthly plan")
var edited=migrated.plan(for:day(8));edited.spendingLimit=6000;migrated.setPlan(edited,for:day(8))
expect(FinancialPlanningStore(defaults:defaults).plan(for:day(8)).spendingLimit == 6000,"legacy migration is idempotent and preserves edited plan")
var cursor=FinancePeriod.month(day(9)).start
while cursor < FinancePeriod.month(day(9)).end { store.covered.insert(cursor);cursor=calendar.date(byAdding:.day,value:1,to:cursor)! }
store.movements=[Movement(date:day(9,1),title:"Ingreso",account:"BBVA",category:"Ingresos",amount:10000,flow:.income,kind:.income),charge(2000)]
let goal = SavingsGoal(name:"Emergencia",target:20000,saved:1000,monthlyContribution:1000)
expect(planning.saveGoal(goal),"goal stored")
expect(planning.closeMonth(day(9),store:store,goalID:goal.id,now:day(10,17)),"covered month closes with explicit destination")
let closed = planning.snapshot(store,month:day(9),now:day(10,17))
expect(planning.state.goals[0].saved == 9000,"closing surplus assigned exactly once")
expect(!planning.closeMonth(day(9),store:store,goalID:goal.id,now:day(10,17)),"duplicate close cannot credit goal again")
expect(planning.setIncomeSources([PlanningIncomeSource(name:"Cambio retroactivo",amount:20000,cadence:"Mensual")],effectiveFrom:day(9)),"explicit historical salary revision accepted")
store.movements.append(charge(1000))
expect(planning.snapshot(store,month:day(9),now:day(10,17)).remaining == closed.remaining,"closing snapshot survives income and ledger changes")
expect(planning.reopenMonth(day(9)) && planning.state.goals[0].saved == 1000,"reopen reverses exact goal assignment")
expect(planning.contribute(to:goal.id,amount:500,date:day(9,20),note:"Aportación"),"dated contribution")
expect(!planning.contribute(to:goal.id,amount:-5000,date:day(9,20),note:"Retiro"),"withdrawal cannot overdraw savings")
expect(planning.state.goals[0].saved == 1500,"failed withdrawal preserves goal")
// Whole backup round trip is isolated to a temporary directory and suite.
let directory=FileManager.default.temporaryDirectory.appendingPathComponent("marcelito-fixture-\(UUID())")
try FileManager.default.createDirectory(at:directory.appendingPathComponent("ImportedStatements"),withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:directory) }
let pdf=Data("%PDF-synthetic".utf8)
try pdf.write(to:directory.appendingPathComponent("ImportedStatements/synthetic.pdf"))
defaults.set("secret-never-export",forKey:"marcelito.auth.token")
defaults.set(["OXXO":"Tiendita"],forKey:"marcelito.categoryRules.v1")
let payload=try FinanceBackup.capture(defaults:defaults,directory:directory)
let preferences=try FinanceBackup.validate(payload)
expect(preferences["marcelito.auth.token"] == nil,"backup excludes access secrets")
let password="solo-prueba-123456"
let encrypted=try FinanceBackup.encrypt(payload,password:password)
let decoded=try FinanceBackup.decrypt(encrypted,password:password)
expect(decoded.files["ImportedStatements/synthetic.pdf"] == pdf,"encrypted backup retains exact PDF bytes")
do { _ = try FinanceBackup.decrypt(encrypted,password:"wrong-password-1234");fatalError("wrong password accepted") } catch { print("PASS: wrong password rejected") }
var tampered=encrypted;tampered[tampered.count/2] ^= 1
do { _ = try FinanceBackup.decrypt(tampered,password:password);fatalError("tampering accepted") } catch { print("PASS: tampered backup rejected") }
let invalid=FinanceBackupPayload(schema:1,createdAt:.now,preferences:payload.preferences,files:["ImportedStatements/../bad":pdf])
do { try FinanceBackup.restore(invalid,defaults:defaults,directory:directory);fatalError("path traversal accepted") } catch { print("PASS: unsafe path rejected before mutation") }
defaults.set(["OXXO":"Otra"],forKey:"marcelito.categoryRules.v1")
try FinanceBackup.restore(decoded,defaults:defaults,directory:directory)
expect(defaults.dictionary(forKey:"marcelito.categoryRules.v1") as? [String:String] == ["OXXO":"Tiendita"],"restore preserves manual merchant rules")
expect(FinancialPlanningStore(defaults:defaults).state.goals[0].saved == 1500,"restore preserves goals and planning history")
let restoredPDF = try Data(contentsOf:directory.appendingPathComponent("ImportedStatements/synthetic.pdf"))
expect(restoredPDF == pdf,"restore preserves source documents")
expect(defaults.string(forKey:"marcelito.auth.token") == "secret-never-export","restore does not replace access credentials")
// Simulate process termination after the recovery journal was written.
try JSONEncoder().encode(payload).write(to:directory.appendingPathComponent("marcelito-restore-rollback.json"),options:.atomic)
defaults.set(["OXXO":"Interrumpido"],forKey:"marcelito.categoryRules.v1")
try FinanceBackup.recoverInterruptedRestore(defaults:defaults,directory:directory)
expect(defaults.dictionary(forKey:"marcelito.categoryRules.v1") as? [String:String] == ["OXXO":"Tiendita"],"interrupted restore recovers prior rules")
expect(!FileManager.default.fileExists(atPath:directory.appendingPathComponent("marcelito-restore-rollback.json").path),"successful recovery clears its journal")
// Deficit months close without assigning negative savings.
let deficitStore = FinanceStore(); deficitStore.covered = store.covered
let deficitPlanning = FinancialPlanningStore(defaults:UserDefaults(suiteName:suite+".deficit")!)
defer { UserDefaults.standard.removePersistentDomain(forName:suite+".deficit") }
deficitPlanning.state.incomeAmount = 1000
deficitStore.movements = [charge(2000)]
expect(deficitPlanning.closeMonth(day(9),store:deficitStore,now:day(10,17)),"deficit month closes without a savings destination")
expect(deficitPlanning.state.goals.isEmpty && deficitPlanning.plan(for:day(9)).closing?.surplus == -2000,"deficit never creates negative savings")
expect(deficitPlanning.reopenMonth(day(9)),"deficit month can be reopened without reversing nonexistent credit")
let msiSuite = UserDefaults(suiteName:suite+".msi")!
defer { msiSuite.removePersistentDomain(forName:suite+".msi") }
let msiPlanning = FinancialPlanningStore(defaults:msiSuite); msiPlanning.state.incomeAmount = 10000
let msiStore = FinanceStore(); var installment = charge(1000); installment.kind = .msi
msiStore.movements = [installment]
msiPlanning.state.installments = [InstallmentCommitment(merchant:"Compra MSI",account:"BBVA",purchaseDate:day(9,15),total:3000,monthly:1000,count:3,firstDueMonth:day(9),linkedMovementIDs:[installment.id],linkedIdentities:[],category:"Compras")]
expect(msiPlanning.total(msiStore,period:.month(day(9))) == 3000,"MSI purchase remains complete in spending")
expect(msiPlanning.snapshot(msiStore,month:day(9),now:day(9,17)).remaining == 9000,"MSI monthly cash commitment deducted once")
let partial=msiPlanning.snapshot(msiStore,month:day(9),now:day(9,17))
expect(partial.remainingDays == 14 && partial.daily == Decimal(9000)/14,"partial month uses remaining calendar days")
expect(msiPlanning.snapshot(msiStore,month:day(9),now:day(10,1)).daily == nil,"ended month never divides by zero days")
print("All planning integrity scenarios passed")
