import type { ImportResult, StatementSource, StatementSummary, Transaction, TransactionKind } from "./types";

const monthNames = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"];

type PdfTextItem = { str: string; transform: number[] };

function rebuildLines(items: unknown[]) {
  const rows: { y: number; parts: { x: number; text: string }[] }[] = [];
  (items as PdfTextItem[]).forEach((item) => {
    if (!item.str?.trim() || !Array.isArray(item.transform)) return;
    const x = item.transform[4] ?? 0;
    const y = item.transform[5] ?? 0;
    let row = rows.find((candidate) => Math.abs(candidate.y - y) < 2.2);
    if (!row) {
      row = { y, parts: [] };
      rows.push(row);
    }
    row.parts.push({ x, text: item.str.trim() });
  });
  return rows
    .sort((a, b) => b.y - a.y)
    .map((row) => row.parts.sort((a, b) => a.x - b.x).map((part) => part.text).join(" "))
    .join("\n");
}

function normalizeAmount(value: string) {
  const clean = value.replace(/[$,\s]/g, "");
  const parsed = Number.parseFloat(clean);
  return Number.isFinite(parsed) ? parsed : 0;
}

function normalizeText(value: string) {
  return value
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase();
}

function detectSource(text: string, fileName: string): StatementSource {
  const haystack = normalizeText(`${text} ${fileName}`);
  if (/american express|amex/.test(haystack)) return "Amex";
  if (/santander/.test(haystack)) return "Santander";
  if (/bbva|bancomer/.test(haystack)) return "BBVA";
  return "Desconocido";
}

function detectPeriod(text: string, fileName: string) {
  const normalized = text.normalize("NFD").replace(/[\u0300-\u036f]/g, "");
  const periodMatch = normalized.match(/period(?:o|os)\s*(?:de\s+facturacion)?\s*[:-]?\s*([^\n]{8,80})/i);
  if (periodMatch?.[1]) return periodMatch[1].replace(/\s+/g, " ").trim();

  const fileLabel = fileName
    .replace(/\.pdf$/i, "")
    .replace(/[_-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  return fileLabel || "Periodo no identificado";
}

function findSummaryAmount(text: string, labels: string[]) {
  const normalized = text.normalize("NFD").replace(/[\u0300-\u036f]/g, "");
  const label = labels.join("|");
  const match = normalized.match(new RegExp(`(?:${label})[^\\d$-]{0,90}(-?\\$?\\s?[\\d,]+(?:\\.\\d{2})?)`, "i"));
  return match?.[1] ? normalizeAmount(match[1]) : undefined;
}

function parseStatementSummary(text: string, source: StatementSource): StatementSummary {
  const summary: StatementSummary = {};
  const values: Array<[keyof StatementSummary, number | undefined]> = [
    ["previousBalance", findSummaryAmount(text, ["saldo anterior", "saldo previo"])],
    ["statementBalance", findSummaryAmount(text, ["saldo nuevo", "saldo al corte", "saldo actual", "saldo deudor"])],
    ["newTransactions", findSummaryAmount(text, ["nuevas transacciones", "compras nuevas"])],
    ["payments", findSummaryAmount(text, ["pagos realizados", "pagos efectuados"])],
    ["credits", findSummaryAmount(text, ["pagos y creditos", "creditos", "abonos"])],
    ["newCharges", findSummaryAmount(text, ["nuevos cargos", "total de cargos"])],
    ["interest", findSummaryAmount(text, ["intereses", "interes del periodo"])],
    ["fees", findSummaryAmount(text, ["comisiones", "comision"])],
    ["creditLimit", findSummaryAmount(text, ["limite de credito", "linea de credito"])],
    ["creditAvailable", findSummaryAmount(text, ["credito disponible", "disponible para compras"])],
    ["minimumPayment", findSummaryAmount(text, ["pago minimo"])],
    ["paymentForNoInterest", findSummaryAmount(text, ["pago para no generar intereses", "pago para no generar interes"])],
  ];
  values.forEach(([key, value]) => {
    if (value !== undefined) (summary as unknown as Record<string, number | undefined>)[key] = value;
  });
  if (source !== "Amex") {
    const cashBalance = findSummaryAmount(text, ["saldo disponible", "saldo final", "saldo actual"]);
    if (cashBalance !== undefined) summary.cashBalance = cashBalance;
  }
  return summary;
}

function guessCategory(description: string) {
  const value = normalizeText(description);
  if (/uber|taxi|metro|gasolina/.test(value)) return "Transporte";
  if (/restaurant|cafe|taquer|comida/.test(value)) return "Comidas";
  if (/mercado|super|amazon/.test(value)) return "Compras";
  if (/hotel|aerolinea|viaje/.test(value)) return "Viajes";
  if (/pago|transfer/.test(value)) return "Transferencia";
  return "Sin categoría";
}

function inferImportedKind(description: string, amount: number, isCredit: boolean): TransactionKind {
  const value = normalizeText(description);
  if (/msi|meses sin intereses|diferid/.test(value)) return "msi";
  if (/interes|interes moratorio/.test(value)) return "interest";
  if (/comision|anualidad/.test(value)) return "fee";
  if (/devolucion|reembolso|bonificacion/.test(value) && amount > 0) return "refund";
  if (/pago.*(tarjeta|amex|credito)|tarjeta.*pago|american express/.test(value)) return "cardPayment";
  if (/transfer|traspaso/.test(value)) return "bankTransfer";
  if (isCredit || amount > 0) return "credit";
  return "purchase";
}

function extractTransactions(text: string, source: StatementSource, fileName: string): Transaction[] {
  const lines = text.split(/\n+/).map((line) => line.replace(/\s+/g, " ").trim()).filter(Boolean);
  const results: Transaction[] = [];
  const datePattern = /^(\d{1,2})\s+(?:de\s+)?(enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|octubre|noviembre|diciembre)/i;
  const amountPattern = /(-?\$?\s?[\d,]+\.\d{2})\s*(CR)?$/i;
  const importKey = normalizeText(fileName).replace(/[^a-z0-9]+/g, "-").slice(0, 28) || "estado";

  lines.forEach((line, index) => {
    const date = line.match(datePattern);
    const amount = line.match(amountPattern);
    if (!date || !amount) return;
    const month = monthNames[["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"].indexOf(normalizeText(date[2]))];
    const rawDescription = line.slice(date[0].length, amount.index).trim();
    if (!rawDescription || rawDescription.length < 3) return;
    const isCredit = Boolean(amount[2]) || /pago|abono|deposito/i.test(rawDescription);
    const value = normalizeAmount(amount[1]) * (isCredit ? 1 : -1);
    const kind = inferImportedKind(rawDescription, value, isCredit);
    const category = kind === "cardPayment" || kind === "bankTransfer" ? "Transferencia" : guessCategory(rawDescription);
    const travelRelated = /viaje|hotel|hospedaje|aerolinea|vuelo|avion|transporte|uber|taxi|metro|renta de auto|destino|equipaje/i.test(normalizeText(rawDescription));
    results.push({
      id: `import-${importKey}-${index}-${value}`,
      date: `${date[1]} ${month}`,
      description: rawDescription.slice(0, 54),
      account: source,
      category,
      amount: value,
      flow: kind === "cardPayment" || kind === "bankTransfer" ? "transfer" : kind === "credit" || kind === "refund" || kind === "income" ? "income" : "expense",
      kind,
      travelRelated,
      confidence: 0.91,
    });
  });

  return results.slice(0, 120);
}

export async function inspectPdf(file: File, onProgress: (value: number, label: string) => void): Promise<ImportResult> {
  onProgress(12, "Abriendo el estado de cuenta");
  const [pdfjs, workerModule] = await Promise.all([
    import("pdfjs-dist"),
    import("pdfjs-dist/build/pdf.worker.min.mjs?url"),
  ]);
  pdfjs.GlobalWorkerOptions.workerSrc = workerModule.default;
  const buffer = await file.arrayBuffer();
  const document = await pdfjs.getDocument({ data: buffer }).promise;
  const pageTexts: string[] = [];

  for (let pageNumber = 1; pageNumber <= document.numPages; pageNumber += 1) {
    const page = await document.getPage(pageNumber);
    const content = await page.getTextContent();
    pageTexts.push(rebuildLines(content.items));
    onProgress(12 + Math.round((pageNumber / document.numPages) * 58), `Leyendo pagina ${pageNumber} de ${document.numPages}`);
  }

  const text = pageTexts.join("\n");
  const source = detectSource(text, file.name);
  const mode = text.replace(/\s/g, "").length > 500 ? "text" : "ocr";
  onProgress(82, mode === "ocr" ? "El PDF requiere reconocimiento visual" : "Conciliando cargos y pagos");

  const parsed = mode === "text" ? extractTransactions(text, source, file.name) : [];
  onProgress(100, "Listo para revisar");

  return {
    source,
    period: detectPeriod(text, file.name),
    fileName: file.name,
    mode,
    transactions: parsed,
    summary: parseStatementSummary(text, source),
  };
}
