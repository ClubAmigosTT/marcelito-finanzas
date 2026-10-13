import XCTest
@testable import Marcelito
final class BankDescriptorContinuationTests:XCTestCase {
 func testTransferContinuationsKeepBeneficiariesAcrossPageWithoutReferenceAmounts(){
  let text="""
  __PDF_PAGE_2__
  BBVA MEXICO Periodo DEL 15/06/2026 AL 14/07/2026
  Detalle de Movimientos Realizados
  27/JUN 29/JUN SPEI RECIBIDONVIO 15,000.00 22,589.63 7,589.63
  8920030INFLUENCER MARKETING Referencia 0155000000 710
  00710000000000000001
  202606279071009000001700000039
  REINVENT MXLATAM
  30/JUN 30/JUN SPEI ENVIADO STP 10,000.00
  0506260credito Referencia 0092000000 646
  La GAT Real es el rendimiento que obtendría después de descontar la inflación estimada
  BBVA MEXICO, S.A., INSTITUCION DE BANCA MULTIPLE
  Av. Paseo de la Reforma 510
  __PDF_PAGE_3__
  Estado de Cuenta
  Libretón Básico Cuenta Digital
  PAGINA 3 / 7
  No. de Cuenta 1234567890
  No. de Cliente B0000000
  00646000000000000001
  MBAN01002606300000000000
  Marcelo Andres Diaz Sanchez
  30/JUN 30/JUN INSTITUTO TECNOLOGIC 10,000.00 2,589.63 2,589.63
  REF:00000000990001802802 CIE:0068447 Referencia GUIA:8528819
  Total de Movimientos
  """
  let r=FinanceStore.readerParseSnapshotForTesting(text:text,fileName:"BBVA2026.pdf",sourceHint:"BBVA")
  XCTAssertEqual(r.movements.count,3);guard r.movements.count==3 else{return}
  XCTAssertEqual(r.movements.map(\.amount),[15000,-10000,-10000]);XCTAssertEqual(r.movements[0].transferRecipient,"Reinvent Mxlatam");XCTAssertEqual(r.movements[1].transferRecipient,"Marcelo Andres Diaz Sanchez")
  XCTAssertTrue(r.movements[0].rawDescription?.contains("INFLUENCER MARKETING")==true);XCTAssertFalse(r.movements[1].rawDescription?.contains("No. de Cuenta")==true);XCTAssertEqual(r.movements[1].extractionEvidence?.page,2)
 }
 func testSantanderLegalBeneficiaryIsPreferredToAliasInConcept(){
  let movement=Movement(date:.now,title:"PAGO TRANSFERENCIA SPEI",account:"Santander",category:"Otros / Por revisar",amount:-100,flow:.expense,
   rawDescription:"ENVIADO A STP AL CLIENTE MARCELO ANDRES DIAZ SANCHEZ (1) DATO NO VERIFICADO CONCEPTO TRANSFERENCIA A MADS RAPPI")
  XCTAssertEqual(movement.transferRecipient,"Marcelo Andres Diaz Sanchez")
 }

}
