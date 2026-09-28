import type { Transaction } from "./types.ts";

const genericCounterparties = new Set([
  "tercero", "terceros", "otro banco", "stp", "santander", "bbva", "banorte",
  "banamex", "citibanamex", "mercado pago", "mercadopago", "bancoppel", "spei",
]);

/** Extracts a beneficiary only when the bank's own row says who it is. */
export function transferRecipientFromText(...sources: Array<string | undefined>) {
  const patterns = [
    /\btransferencia\s+a\s+(.+?)(?=\s+\b(?:iva|rfc|ref(?:erencia)?|clave\s+de\s+rastreo|rastreo|folio|cuenta|clabe|concepto)\b|\s+[-+]?\s*\$?\s*\d[\d, ]*(?:[.,]\d{2})|$)/i,
    /\b(?:a\s+favor\s+de|beneficiari[oa]|destinatari[oa])\s*[:#-]?\s*(.+?)(?=\s+\b(?:iva|rfc|ref(?:erencia)?|clave\s+de\s+rastreo|rastreo|folio|cuenta|clabe|concepto)\b|\s+[-+]?\s*\$?\s*\d[\d, ]*(?:[.,]\d{2})|$)/i,
    /\bspei\s+enviado\s+(?:a\s+)?(.+?)(?=\s+\b(?:iva|rfc|ref(?:erencia)?|clave\s+de\s+rastreo|rastreo|folio|cuenta|clabe|concepto)\b|\s+[-+]?\s*\$?\s*\d[\d, ]*(?:[.,]\d{2})|$)/i,
  ];
  for (const source of sources) {
    if (!source) continue;
    for (const pattern of patterns) {
      const match = source.match(pattern);
      if (!match?.[1]) continue;
      const recipient = match[1]
        .replace(/^\s*a\s+/i, "")
        .replace(/\s+/g, " ")
        .replace(/^[\s:;,.|-]+|[\s:;,.|-]+$/g, "")
        .trim();
      const normalized = recipient.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
      if (!recipient || recipient.length > 80 || genericCounterparties.has(normalized)) continue;
      return recipient.replace(/\p{L}[\p{L}'’-]*/gu, (word) => word.toLocaleLowerCase("es-MX").replace(/^./u, (first) => first.toLocaleUpperCase("es-MX")));
    }
  }
  return undefined;
}

export function transactionSummaryTitle(transaction: Pick<Transaction, "description" | "flow" | "amount"> & Partial<Pick<Transaction, "rawDescription" | "displayDescription" | "displayMerchant" | "extractionEvidence">>) {
  const sources = [
    transaction.rawDescription,
    transaction.description,
    transaction.displayDescription,
    transaction.extractionEvidence?.sourceText,
  ];
  const recipient = transferRecipientFromText(...sources);
  if (!recipient) return transaction.displayMerchant?.trim() || transaction.description;
  const text = sources.filter(Boolean).join(" ").normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
  const rail = text.includes("spei") ? "SPEI" : "Transferencia";
  return rail + (transaction.amount < 0 ? " a " : " de ") + recipient;
}
