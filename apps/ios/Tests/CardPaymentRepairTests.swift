import XCTest
@testable import Marcelito
@MainActor
final class CardPaymentRepairTests: XCTestCase {
 private func day(_ d: Int) -> Date { Calendar(identifier: .gregorian).date(from: DateComponents(year:2026,month:6,day:d))! }
 private func statement(_ source:String,_ kind:StatementKind)->StatementRecord {
  StatementRecord(id:UUID(),source:source,accountKey:source+":1001",period:"01/06/2026 - 30/06/2026",fileName:"fixture.pdf",importedAt:.now,transactionCount:0,requiresReview:false,kind:kind,
   reconciliation:StatementReconciliationRecord(status:.valid,tolerance:0),sourceDetection:SourceDetectionEvidence(source:source,confidence:1,status:.verified,evidence:["fixture"],ignoredBodyMentions:[]),readerVersion:FinanceStore.readerVersion)
 }
 private func run(_ f:(FinanceStore)->Void) {
  let store=FinanceStore();store.clearLocalData();defer{store.clearLocalData()}
  let bank=statement("Santander",.bank),card=statement("Rappi",.card);store.statements=[bank,card]
  store.movements=[Movement(date:day(15),title:"PAGO TRANSFERENCIA SPEI CONCEPTO TRANSFERENCIA A MADS RAPPI",account:"Santander",category:"Transporte",amount:-1200,flow:.expense,statementId:bank.id,kind:.purchase,
   extractionEvidence:.init(method:"fixture",page:2,confidence:1,sourceText:"original"),rawDescription:"ENVIADO A STP A LA CUENTA 646000000000000001 AL CLIENTE MARCELO ANDRES DIAZ SANCHEZ CONCEPTO TRANSFERENCIA A MADS RAPPI"),
   Movement(date:day(13),title:"PAGO POR SPEI",account:"Rappi",category:"Transferencia",amount:1200,flow:.transfer,statementId:card.id,kind:.cardPayment)]
  f(store)
 }
 func testPaymentKeepsPurchasesAndManualCategoryAcrossReload(){run{ s in
  _=s.updateCategory(for:s.movements[0],to:"Entrenamiento",applyToMerchant:false)
  var buy=s.movements[1];buy.id=UUID();buy.amount = -700;buy.kind = .purchase;buy.flow = .expense;buy.title="Restaurante";s.movements.append(buy)
  s.normalizeFinanceForTesting();XCTAssertEqual(s.movements[0].kind,.cardPayment);XCTAssertEqual(s.movements[0].matchedMovementId,s.movements[1].id);XCTAssertEqual(s.consolidatedRealSpend,700)
  _=s.updateCategory(for:s.movements[2],to:"Restaurantes y bares",applyToMerchant:false)
  FinanceStore.recordCanonicalRebuildCompletion(in:.standard);let r=FinanceStore();r.normalizeFinanceForTesting()
  XCTAssertEqual(r.consolidatedRealSpend,700);XCTAssertEqual(r.movements[0].category,"Entrenamiento");XCTAssertEqual(r.movements[0].matchedMovementId,r.movements[1].id)
 }}
 func testExplicitAccountingReviewNeedsConfirmationAndRejectsSecondTap(){run{ s in
  s.updateClassification(for:s.movements[0],kind:.purchase,travelRelated:false);s.normalizeFinanceForTesting()
  XCTAssertEqual(s.movements[0].kind,.purchase);XCTAssertEqual(s.pendingTransferReviewPairs.count,1)
  let pair=s.pendingTransferReviewPairs[0];XCTAssertTrue(pair.isCardPayment);XCTAssertTrue(s.confirmPaymentPair(pair));XCTAssertFalse(s.confirmPaymentPair(pair));XCTAssertEqual(s.movements[0].category,"Transporte")
  FinanceStore.recordCanonicalRebuildCompletion(in:.standard);let r=FinanceStore();r.normalizeFinanceForTesting();XCTAssertEqual(r.movements[0].matchedMovementId,r.movements[1].id);XCTAssertTrue(r.pendingTransferReviewPairs.isEmpty)
 }}
 func testLegacyReviewStaysProtected(){run{ s in
  s.movements[0].manuallyReviewed=true;s.movements[0].manuallyAccountingReviewed=nil;s.normalizeFinanceForTesting()
  XCTAssertEqual(s.movements[0].kind,.purchase);XCTAssertEqual(s.movements[0].category,"Transporte");XCTAssertEqual(s.pendingTransferReviewPairs.count,1)
 }}
 func testRappiCannotPairWithAmexOrNvioIncome(){run{ s in
  let amex=statement("Amex",.card),bbva=statement("BBVA",.bank);s.statements += [amex,bbva];s.movements[1].account="Amex";s.movements[1].statementId=amex.id
  var pay=s.movements[1];pay.id=UUID();pay.account="BBVA";pay.statementId=bbva.id;pay.kind = .income;pay.flow = .income;pay.title="SPEI RECIBIDONVIO";s.movements.append(pay)
  s.normalizeFinanceForTesting();XCTAssertNil(s.movements[0].matchedMovementId);XCTAssertEqual(s.movements[2].kind,.income);XCTAssertFalse(s.pendingTransferReviewPairs.contains{$0.isCardPayment})
 }}
 func testThirdPartyMentionDoesNotHideExpense(){run{ s in
  s.movements[0].rawDescription="AL CLIENTE PERSONA DISTINTA";s.normalizeFinanceForTesting();XCTAssertNil(s.movements[0].matchedMovementId)
 }}
 func testAmbiguousReceiptsStayPending(){run{ s in
  var second=s.movements[1];second.id=UUID();second.date=day(14);s.movements.append(second);s.normalizeFinanceForTesting()
  XCTAssertNil(s.movements[0].matchedMovementId);XCTAssertEqual(s.pendingTransferReviewPairs.filter(\.isCardPayment).count,2)
 }}
 func testRejectedPaymentStaysRejectedAfterNormalizationAndReload(){run{ s in
  s.rejectTransferPair(s.pendingTransferReviewPairs[0]);s.normalizeFinanceForTesting();XCTAssertNil(s.movements[0].matchedMovementId)
  FinanceStore.recordCanonicalRebuildCompletion(in:.standard);let r=FinanceStore();r.normalizeFinanceForTesting();XCTAssertNil(r.movements[0].matchedMovementId);XCTAssertTrue(r.pendingTransferReviewPairs.isEmpty)
 }}
 func testExactDestinationLinksSTPWithoutTreatingAllSTPAsPayments(){run{ s in
  var other=s.movements[0];other.id=UUID();other.date=day(30);other.amount = -10000;other.title="SPEI ENVIADO STP";other.rawDescription="SPEI ENVIADO STP\n00646000000000000001\nMarcelo Andres Diaz Sanchez"
  var card=s.movements[1];card.id=UUID();card.date=day(30);card.amount=10000;s.movements += [other,card];s.normalizeFinanceForTesting();XCTAssertEqual(s.movements[2].matchedMovementId,s.movements[3].id)
 }}
 func testCentDifferenceAndPostingWindow(){run{ s in
  s.movements[1].amount=Decimal(string:"1200.01")!;s.normalizeFinanceForTesting();XCTAssertNil(s.movements[0].matchedMovementId)
  s.movements[1].amount=1200;s.movements[1].date=day(1);s.normalizeFinanceForTesting();XCTAssertNil(s.movements[0].matchedMovementId)
 }}
 func testDescriptorReplayRetainsExplicitCategoryAndType(){run{ s in
  _=s.updateCategory(for:s.movements[0],to:"Itam",applyToMerchant:false);s.updateClassification(for:s.movements[0],kind:.purchase,travelRelated:false)
  s.movements[0].id=UUID();s.movements[0].extractionEvidence?.sourceText="original and recovered continuation";s.movements[0].category="Otros / Por revisar";s.movements[0].manuallyReviewed=false;s.movements[0].manuallyAccountingReviewed=false
  s.normalizeFinanceForTesting();XCTAssertEqual(s.movements[0].category,"Itam");XCTAssertEqual(s.movements[0].kind,.purchase);XCTAssertTrue(s.movements[0].accountingReviewLocked)
 }}
 func testAmbiguousFundingIncludesProtectedPurchase(){run{ s in
  var other=s.movements[0];other.id=UUID();other.date=day(14)
  other.manuallyReviewed=true;other.manuallyAccountingReviewed=true;s.movements.append(other)
  s.normalizeFinanceForTesting();XCTAssertNil(s.movements[0].matchedMovementId);XCTAssertEqual(s.movements[2].kind,.purchase)
 }}
 func testDuplicateImportedAfterAutomaticPairRequiresReviewAgain(){run{ s in
  s.normalizeFinanceForTesting();XCTAssertNotNil(s.movements[0].matchedMovementId)
  var second=s.movements[1];second.id=UUID();second.date=day(14);second.matchedMovementId=nil;second.reconciliationReason=nil;s.movements.append(second)
  s.normalizeFinanceForTesting();XCTAssertNil(s.movements[0].matchedMovementId)
 }}

 func testUnreconciledCardCannotHideFunding(){run{ s in
  s.statements[1].requiresReview=true;s.normalizeFinanceForTesting()
  XCTAssertNil(s.movements[0].matchedMovementId);XCTAssertEqual(s.movements[0].kind,.purchase)
 }}

 func testOwnerNameInReferenceDoesNotProveRecipientIsOwn(){run{ s in
  s.movements[0].rawDescription="PAGO RAPPICARD AL CLIENTE OTRA PERSONA (1) CONCEPTO PARA MARCELO ANDRES DIAZ SANCHEZ"
  s.normalizeFinanceForTesting();XCTAssertNil(s.movements[0].matchedMovementId);XCTAssertEqual(s.movements[0].kind,.purchase)
 }}
 func testPaymentWithoutRecipientIsOnlyAReviewProposal(){run{ s in
  s.movements[0].rawDescription="PAGO RAPPICARD";s.normalizeFinanceForTesting()
  XCTAssertNil(s.movements[0].matchedMovementId);XCTAssertEqual(s.pendingTransferReviewPairs.filter(\.isCardPayment).count,1)
 }}

 func testAmexNegativeReceiptIsPaymentNotPurchase(){run{ s in
  let amex=statement("Amex",.card);s.statements[1]=amex
  s.movements[0].title="DOMICILIACION PAGO SERVICIO AMERICAN EXPRESS";s.movements[0].rawDescription=nil
  s.movements[1].account="Amex";s.movements[1].statementId=amex.id;s.movements[1].amount = -1200;s.movements[1].flow = .debt;s.movements[1].title="GRACIAS POR SU PAGO EN LINEA"
  s.normalizeFinanceForTesting();XCTAssertEqual(s.movements[0].matchedMovementId,s.movements[1].id);XCTAssertEqual(s.consolidatedRealSpend,0)
  _=s.updateCategory(for:s.movements[0],to:"Comisiones y finanzas",applyToMerchant:false)
  s.normalizeFinanceForTesting();XCTAssertEqual(s.consolidatedRealSpend,0)
 }}

 func testGenericPaymentLabelNeedsExplicitConfirmation(){run{ s in
  s.movements[0].rawDescription="PAGO DE TARJETA";s.normalizeFinanceForTesting()
  XCTAssertNil(s.movements[0].matchedMovementId);XCTAssertEqual(s.pendingTransferReviewPairs.filter(\.isCardPayment).count,1)
 }}
 func testUnlinkedNegativeReceiptNeverBecomesExpense(){run{ s in
  let amex=statement("Amex",.card);s.statements[1]=amex
  s.movements[0].rawDescription="PAGO DE TARJETA";s.movements[0].kind = .cardPayment;s.movements[0].flow = .transfer
  s.movements[1].account="Amex";s.movements[1].statementId=amex.id;s.movements[1].amount = -1200;s.movements[1].flow = .transfer;s.movements[1].title="GRACIAS POR SU PAGO EN LINEA"
  s.movements[0].matchedMovementId=s.movements[1].id;s.movements[1].matchedMovementId=s.movements[0].id
  s.movements[0].reconciliationReason="Old guess";s.movements[1].reconciliationReason="Old guess"
  s.normalizeFinanceForTesting();XCTAssertEqual(s.movements[1].kind,.cardPayment);XCTAssertEqual(s.consolidatedRealSpend,1200)
  let pair=s.pendingTransferReviewPairs[0];XCTAssertTrue(s.confirmPaymentPair(pair));s.normalizeFinanceForTesting();XCTAssertEqual(s.consolidatedRealSpend,0)
 }}

}
