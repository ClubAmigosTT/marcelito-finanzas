import type { ImportResult, StatementSource, Transaction } from "./types";

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

function guessCategory(description: string) {
  const value = normalizeText(description);
  if (/uber|taxi|metro|gasolina/.test(value)) return "Transporte";
  if (/restaurant|cafe|taquer|comida/.test(value)) return "Comidas";
  if (/mercado|super|amazon/.test(value)) return "Compras";
  if (/hotel|aerolinea|viaje/.test(value)) return "Viajes";
  if (/pago|transfer/.test(value)) return "Transferencia";
  return "Sin categoría";
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
    const isCredit = Boolean(amount[2]) || /pago|abono|dep[oó]sito/i.test(rawDescription);
    const value = normalizeAmount(amount[1]) * (isCredit ? 1 : -1);
    const category = guessCategory(rawDescription);
    results.push({
      id: `import-${importKey}-${index}-${value}`,
      date: `${date[1]} ${month}`,
      description: rawDescription.slice(0, 54),
      account: source,
      category,
      amount: value,
      flow: isCredit ? (category === "Transferencia" ? "transfer" : "income") : "expense",
      confidence: 0.91,
    });
  });

  return results.slice(0, 80);
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
    onProgress(12 + Math.round((pageNumber / document.numPages) * 58), `Leyendo página ${pageNumber} de ${document.numPages}`);
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
  };
}
