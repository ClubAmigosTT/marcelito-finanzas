from pathlib import Path
src=(Path(__file__).resolve().parents[1]/'apps/ios/Cauce/Models.swift').read_text()
import tempfile,subprocess
out=Path(tempfile.mkdtemp(prefix='marcelito-transfer-test-'))
names=['transferDescriptor','exactTransferAmountsMatch','canAutomaticallyMatch','transferCounterparts','transferPairReviewKey','confirmOwnTransfer','amountsMatch','hasTransferHint','containsWholePhrase','ownerAliasMentioned','transferReferenceTokens','transferPairEvidence','hasIndependentTransferLink','globallyBestTransferCandidates','hasCardPaymentHint','isOutflow','isInflow','reconcileStoredMovements','movementKind','isSpend','isRealIncome','updateClassification']
def extract(name):
 start=src.index('    private func '+name+'(') if '    private func '+name+'(' in src else src.index('    func '+name+'(')
 i=src.index('{',start);level=1;j=i+1
 while level:
  level+=(src[j]=='{')-(src[j]=='}');j+=1
 return src[start:j].replace('private func','func')
header='''import Foundation
enum FlowKind { case income, expense, transfer, debt }
enum MovementKind { case purchase, cardPayment, bankTransfer, income, credit, refund, msi, interest, fee, other }
enum AccountKind { case bank, card }
struct Statement { var id = UUID(); var source: String; var kind: AccountKind }
struct Evidence {var sourceText:String?}
struct Movement { var id = UUID(); var date: Date; var title: String; var account: String; var category = "Otros"; var amount: Decimal; var flow: FlowKind; var statementId: UUID?; var kind: MovementKind?; var manuallyReviewed = false; var manuallyAccountingReviewed:Bool?; var accountingReviewLocked:Bool {manuallyAccountingReviewed ?? manuallyReviewed};var confirmedCounterpartKey:String?;var rawDescription:String?;var extractionEvidence:Evidence?; var matchedMovementId: UUID?; var reconciliationConfidence: Int?; var reconciliationReason: String?; var travelRelated = false; var classificationTags: [String] = [] }
struct CaptureSource {var kind: AccountKind}
struct Capture {var movements:[Movement];var source:CaptureSource}
struct DiagnosticsRecorder {static func record(level:String, stage:String,message:String) {}}
class Probe {
 var movements:[Movement] = []
 var statements = [Statement(source:"BBVA",kind:.bank),Statement(source:"Santander",kind:.bank),Statement(source:"Amex",kind:.card)]
 var transferOwnerAliases = ["Marcelo Díaz", "Marcelo A. Díaz", "Díaz Marcelo"]
 var screenshotCaptures:[Capture] = []
 var rejectedTransferPairKeys = Set<String>()
 func isEligibleMovement(_ m:Movement)->Bool {true}
 func absolute(_ x:Decimal)->Decimal {abs(x)}
 func normalizedConcept(_ s:String)->String {s.folding(options:[.diacriticInsensitive,.caseInsensitive],locale:.current).lowercased()}
 func statementKind(_ s:Statement)->AccountKind {s.kind}
 func statementForMovement(_ m:Movement)->Statement? {statements.first{$0.source == m.account}}
 func isBankMovement(_ m:Movement)->Bool {m.account != "Amex"}
 func isCardMovement(_ m:Movement)->Bool {m.account == "Amex"}
 func distinctImportedBankAccounts(_ a:Movement,_ b:Movement)->Bool {isBankMovement(a) && isBankMovement(b) && a.account != b.account}
 func isProvisionalScreenshotMovement(_ m:Movement)->Bool {false}
 func persist(markingChange:Bool) {}
 func manualReviewKey(_ m:Movement)->String {"\(m.account)|\(m.date)|\(m.amount)|\(m.title)"}
 static func category(for title:String, flow:FlowKind)->String {"Otros"}
 struct ScoredTransferCandidate {let outflowIndex:Int;let inflowIndex:Int;let amountKey:String;let score:Int;let reason:String;let dateDistance:TimeInterval}
 func row(_ title:String,_ amount:Decimal,_ account:String,_ reviewed:Bool=false)->Movement {Movement(date:Date(timeIntervalSince1970:1788220800),title:title,account:account,amount:amount,flow:amount < 0 ? .expense : .income,kind:amount < 0 ? .purchase : .income,manuallyReviewed:reviewed)}
 func summary(_ name:String) {let spend=movements.filter(isSpend).reduce(Decimal(0)){$0+abs($1.amount)};let income=movements.filter(isRealIncome).reduce(Decimal(0)){$0+abs($1.amount)};print("\\(name)|spend=\\(spend)|income=\\(income)|linked=\\(movements.filter{$0.matchedMovementId != nil}.count)|transfers=\\(movements.filter{$0.kind == .bankTransfer}.count)")}
}
'''
# Inject unchanged production method bodies into an isolated Foundation-only shell.
alias_start=src.index('    private static let defaultTransferOwnerAliases = [')
alias_end=src.index(']',alias_start)+1
header=header.replace('var transferOwnerAliases = ["Marcelo Díaz", "Marcelo A. Díaz", "Díaz Marcelo"]',src[alias_start:alias_end].replace('private static let defaultTransferOwnerAliases','var transferOwnerAliases').strip())
header=header.rsplit('}',1)[0]+'\n'+'\n'.join(extract(n) for n in names)+'\n}\n'
tests='''
let s=Probe()
func pair(_ reviewed:Bool=false) {s.movements=[s.row("SPEI ENVIADO Marcelo Díaz REF ABC123",-3000,"BBVA",reviewed),s.row("SPEI RECIBIDO REF ABC123",3000,"Santander")]}
pair();s.reconcileStoredMovements();s.summary("verified_pair")
s.reconcileStoredMovements();s.summary("verified_pair_second_pass")
pair(true);s.reconcileStoredMovements();s.summary("category_review_before_pairing")
pair();s.updateClassification(for:s.movements[0],kind:.bankTransfer,travelRelated:false);s.summary("manual_transfer_one_side");s.reconcileStoredMovements();s.summary("manual_transfer_after_audit")
pair();s.reconcileStoredMovements();s.movements[0].manuallyReviewed=true;s.reconcileStoredMovements();s.summary("category_review_after_pairing")
s.movements=[s.row("SPEI ENVIADO",-3000,"BBVA"),s.row("SPEI RECIBIDO",3000,"Santander")];s.reconcileStoredMovements();s.summary("generic_ambiguous_pair")
s.movements=[s.row("SPEI ENVIADO Marcelo Andres Diaz Sanc",-3000,"BBVA"),s.row("SPEI RECIBIDO",3000,"Santander")];s.reconcileStoredMovements();s.summary("full_owner_name_default_alias")
s.movements=[s.row("SPEI ENVIADO REF ABC123",-3000,"BBVA"),s.row("SPEI RECIBIDO REF ABC123",3000,"Santander"),s.row("SPEI RECIBIDO REF ABC123",3000,"Santander")];s.reconcileStoredMovements();s.summary("ambiguous_two_counterparts")
s.movements=[s.row("SPEI ENVIADO REF ABC123",-3000,"BBVA"),s.row("SPEI RECIBIDO REF ABC123",3000.01,"Santander")];s.reconcileStoredMovements();s.summary("one_cent_difference")
s.movements=[s.row("Pago de tarjeta Amex",-3000,"BBVA"),s.row("Pago de tarjeta Amex",-3000,"Santander"),s.row("GRACIAS POR SU PAGO",3000,"Amex")];s.movements[2].kind = .cardPayment;s.reconcileStoredMovements();s.summary("two_banks_one_card_payment")
'''
(out/'probe.swift').write_text(header+tests)


with (out/'probe.swift').open('a') as f:
 f.write("""
pair();s.movements[0].manuallyReviewed=true;s.movements[0].manuallyAccountingReviewed=false;s.reconcileStoredMovements();s.summary("new_category_before_pair")
pair();s.reconcileStoredMovements();s.movements[0].manuallyReviewed=true;s.movements[0].manuallyAccountingReviewed=false;s.reconcileStoredMovements();s.summary("new_category_after_pair")
s.movements=[s.row("SPEI ENVIADO",-3000,"BBVA"),s.row("SPEI RECIBIDO",3000,"Santander")];assert(s.confirmOwnTransfer(s.movements[0],counterpart:s.movements[1]));s.summary("confirmed_ambiguous_pair");s.movements[0].id=UUID();s.movements[1].id=UUID();s.reconcileStoredMovements();s.summary("confirmed_pair_recreated_ids")
pair();s.movements[0].rawDescription="SPEI REF ZZZ999";s.movements[1].rawDescription="SPEI REF ZZZ999";s.movements[0].title="SPEI";s.movements[1].title="SPEI RECIBIDO";s.reconcileStoredMovements();s.summary("full_descriptor_reference")
""")
r=subprocess.run(['swift','-module-cache-path','/private/tmp/marcelito-transfer-test-cache',str(out/'probe.swift')],capture_output=True,text=True)
if r.returncode: print(r.stderr);raise SystemExit(r.returncode)
rows={}
for line in r.stdout.splitlines():
 bits=line.split('|');rows[bits[0]]=dict(b.split('=') for b in bits[1:])
expected={'verified_pair':('0','0','2'),'verified_pair_second_pass':('0','0','2'),'category_review_after_pairing':('0','0','2'),'manual_transfer_after_audit':('0','0','2'),'category_review_before_pairing':('3000','3000','0'),'one_cent_difference':('3000','3000.01','0'),'full_owner_name_default_alias':('3000','3000','0'),'two_banks_one_card_payment':('6000','0','0'),'new_category_before_pair':('0','0','2'),'new_category_after_pair':('0','0','2'),'confirmed_ambiguous_pair':('0','0','2'),'confirmed_pair_recreated_ids':('0','0','2'),'full_descriptor_reference':('0','0','2')}
for name,value in expected.items():
 actual=rows[name];assert (actual['spend'],actual['income'],actual['linked'])==value,(name,actual,value)
print(r.stdout);print(f'{len(expected)} regression assertions passed; production Swift method bodies, isolated account/persistence helpers.')
