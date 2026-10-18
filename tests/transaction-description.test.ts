import assert from "node:assert/strict";
import test from "node:test";
import { transactionSummaryTitle, transferRecipientFromText } from "../src/transactionDescription.ts";

test("identifica el beneficiario explícito sin agregar referencias técnicas", () => {
  assert.equal(
    transferRecipientFromText("PAGO TRANSF RAPIDA SPEI TRANSFERENCIA A ARACELI CASTILLO IVA REF 858573"),
    "Araceli Castillo",
  );
  assert.equal(transferRecipientFromText("PAGO TRANSFERENCIA SPEI HORA 13:13 CONCEPTO TRANSFERENCIA A MADS RAPPI"), "Mads Rappi");
});

test("no trata bancos intermediarios ni SPEI genérico como persona", () => {
  assert.equal(transferRecipientFromText("SPEI ENVIADO STP"), undefined);
  assert.equal(transferRecipientFromText("SPEI ENVIADO A TERCEROS"), undefined);
});

test("muestra la contraparte en el título resumido sin modificar la descripción", () => {
  assert.equal(transactionSummaryTitle({
    description: "SPEI ENVIADO A MARCELO ANDRES DIAZ RFC ABC010203",
    flow: "expense",
    amount: -1000,
  }), "SPEI a Marcelo Andres Diaz");
});
