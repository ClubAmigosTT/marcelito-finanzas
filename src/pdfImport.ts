import type { ImportResult, StatementKind, StatementSource, StatementSummary, Transaction, TransactionKind } from "./types";

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
  let clean = value.replace(/[$\s]/g, "").trim();
  const comma = clean.lastIndexOf(",");
  const dot = clean.lastIndexOf(".");
  if (comma >= 0 && dot >= 0) {
    clean = comma > dot
      ? clean.replace(/\./g, "").replace(",", ".")
      : clean.replace(/,/g, "");
  } else if (comma >= 0) {
    const decimals = clean.length - comma - 1;
    clean = decimals === 1 || decimals === 2 ? clean.replace(",", ".") : clean.replace(/,/g, "");
  }
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
  if (/santander/.test(haystack)) return "Santander";
  if (/bbva|bancomer/.test(haystack)) return "BBVA";
  if (/american express|amex/.test(haystack)) return "Amex";
  const otherBanks: Array<[string, RegExp]> = [
    ["Banorte", /\bbanorte\b/],
    ["HSBC", /\bhsbc\b/],
    ["Scotiabank", /\bscotiabank\b/],
    ["Citibanamex", /\bcitibanamex\b|\bbanamex\b/],
    ["Inbursa", /\binbursa\b/],
    ["Banco Azteca", /banco azteca/],
    ["Banco del Bajío", /banco del bajio/],
    ["Mifel", /\bmifel\b/],
    ["INVEX", /\binvex\b/],
    ["Hey Banco", /hey banco/],
    ["Nu", /\bnu(?: mexico| banco)?\b/],
    ["Klar", /\bklar\b/],
    ["Rappi", /\brappi\b/],
    ["Ualá", /\buala\b/],
  ];
  const detected = otherBanks.find(([, marker]) => marker.test(haystack))?.[0];
  if (detected) return detected;
  return "Desconocido";
}

function detectStatementKind(text: string, source: StatementSource): StatementKind {
  if (source === "Amex") return "card";
  if (source === "Santander" || source === "BBVA") return "bank";
  const normalized = normalizeText(text);
  const cardMarkers = [
    "tarjeta de credito", "tarjetahabiente", "credito disponible",
    "limite de credito", "linea de credito", "pago minimo", "saldo deudor",
    "credit card", "mastercard", "visa credit",
  ];
  const bankMarkers = [
    "cuenta de cheques", "cuenta de ahorro", "cuenta clabe", "estado de cuenta nomina",
    "super nomina", "depositos", "retiros", "saldo final", "saldo disponible", "cuenta corriente",
    "banorte", "hsbc", "scotiabank", "citibanamex", "banamex", "inbursa", "banco azteca",
    "banco del bajio", "mifel", "invex", "hey banco", "nu mexico", "nu banco", "klar", "rappi", "uala",
  ];
  const cardScore = cardMarkers.filter((marker) => normalized.includes(marker)).length;
  const bankScore = bankMarkers.filter((marker) => normalized.includes(marker)).length;
  if (cardScore >= 2 && cardScore >= bankScore) return "card";
  if (bankScore >= 2) return "bank";
  return "unknown";
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

function parseStatementSummary(text: string, kind: StatementKind): StatementSummary {
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
  if (kind !== "card") {
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
  const datePattern = /^(?:(\d{1,2})\s+(?:de\s+)?(enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|setiembre|octubre|noviembre|diciembre|ene|feb|mar|abr|may|jun|jul|ago|sep|set|oct|nov|dic)(?:\s+(?:de\s+)?(\d{2,4}))?|(?:(\d{1,2})[-/.](\d{1,2})[-/.](\d{2,4}))|(?:(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})))/i;
  const amountPattern = /(?:^|\s)([-+]?\s*\$?(?:\d{1,3}(?:[ ,.]\d{3})+(?:[.,]\d{1,2})?|\d+(?:[.,]\d{1,2})?))\s*(CR)?$/i;
  const importKey = normalizeText(fileName).replace(/[^a-z0-9]+/g, "-").slice(0, 28) || "estado";
  const monthIndex = (token: string) => {
    const value = normalizeText(token);
    const full = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"];
    const index = full.findIndex((month) => month.startsWith(value) || value.startsWith(month.slice(0, 3)));
    if (value.startsWith("sep") || value.startsWith("set")) return 8;
    return index >= 0 ? index : 0;
  };
  const formatDate = (match: RegExpMatchArray) => {
    if (match[1] && match[2]) return `${match[1]} ${monthNames[monthIndex(match[2])]}${match[3] ? ` ${match[3]}` : ""}`;
    if (match[4] && match[5] && match[6]) return `${match[4]} ${monthNames[Math.max(0, Number(match[5]) - 1)]} ${match[6]}`;
    if (match[7] && match[8] && match[9]) return `${match[9]} ${monthNames[Math.max(0, Number(match[8]) - 1)]} ${match[7]}`;
    return "Sin fecha";
  };

  lines.forEach((line, index) => {
    const date = line.match(datePattern);
    const amount = line.match(amountPattern);
    if (!date || !amount) return;
    const rawDescription = line.slice(date[0].length, amount.index ?? line.length).trim();
    if (!rawDescription || rawDescription.length < 3) return;
    const normalizedDescription = normalizeText(rawDescription);
    const isRefund = /devolucion|reembolso|bonificacion/.test(normalizedDescription);
    const isCardPayment = /gracias por su pago|pago de tarjeta|pago.*(?:tarjeta|credito)|tarjeta.*pago/.test(normalizedDescription);
    const isIncome = /nomina|sueldo|salario|deposito|abono|ingreso|transferencia recibida/.test(normalizedDescription);
    const isTransfer = /transfer|traspaso|spei|entre cuentas|clabe/.test(normalizedDescription);
    const isCredit = Boolean(amount[2]) || isRefund || isIncome;
    const flow: Transaction["flow"] = isRefund || isIncome ? "income" : isCardPayment ? "debt" : isTransfer ? "transfer" : "expense";
    const value = normalizeAmount(amount[1]) * (flow === "income" ? 1 : -1);
    const kind = inferImportedKind(rawDescription, value, isCredit);
    const category = kind === "cardPayment" || kind === "bankTransfer" ? "Transferencia" : guessCategory(rawDescription);
    const travelRelated = /viaje|hotel|hospedaje|aerolinea|vuelo|avion|transporte|uber|taxi|metro|renta de auto|destino|equipaje/i.test(normalizeText(rawDescription));
    results.push({
      id: `import-${importKey}-${index}-${value}`,
      date: formatDate(date),
      description: rawDescription.slice(0, 54),
      account: source,
      category,
      amount: value,
      flow,
      kind,
      travelRelated,
      confidence: 0.86,
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
  const kind = detectStatementKind(text, source);
  const mode = text.replace(/\s/g, "").length > 500 ? "text" : "ocr";
  onProgress(82, mode === "ocr" ? "El PDF requiere reconocimiento visual" : "Conciliando cargos y pagos");

  const parsed = mode === "text" ? extractTransactions(text, source, file.name) : [];
  onProgress(100, "Listo para revisar");

  return {
    source,
    kind,
    period: detectPeriod(text, file.name),
    fileName: file.name,
    mode,
    transactions: parsed,
    summary: parseStatementSummary(text, kind),
  };
}
