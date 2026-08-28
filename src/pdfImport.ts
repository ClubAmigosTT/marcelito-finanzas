import type { ImportResult, Transaction } from "./types";

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

function guessCategory(description: string) {
  const value = description.toLowerCase();
  if (/uber|taxi|metro|gasolina/.test(value)) return "Transporte";
  if (/restaurant|cafe|taquer|comida/.test(value)) return "Comidas";
  if (/mercado|super|amazon/.test(value)) return "Compras";
  if (/hotel|aerolinea|viaje/.test(value)) return "Viajes";
  if (/pago|transfer/.test(value)) return "Transferencia";
  return "Sin categoría";
}

function extractTransactions(text: string, source: ImportResult["source"]): Transaction[] {
  const lines = text.split(/\n+/).map((line) => line.replace(/\s+/g, " ").trim()).filter(Boolean);
  const results: Transaction[] = [];
  const datePattern = /^(\d{1,2})\s+(?:de\s+)?(enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|octubre|noviembre|diciembre)/i;
  const amountPattern = /(-?\$?\s?[\d,]+\.\d{2})\s*(CR)?$/i;

  lines.forEach((line, index) => {
    const date = line.match(datePattern);
    const amount = line.match(amountPattern);
    if (!date || !amount) return;
    const month = monthNames[["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"].indexOf(date[2].toLowerCase())];
    const rawDescription = line.slice(date[0].length, amount.index).trim();
    if (!rawDescription || rawDescription.length < 3) return;
    const isCredit = Boolean(amount[2]) || /pago|abono|dep[oó]sito/i.test(rawDescription);
    const value = normalizeAmount(amount[1]) * (isCredit ? 1 : -1);
    const category = guessCategory(rawDescription);
    results.push({
      id: `import-${index}-${value}`,
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
  let source: ImportResult["source"] = /american express|amex/i.test(text + file.name) ? "Amex" : /santander/i.test(text + file.name) ? "Santander" : "Desconocido";
  const mode = text.replace(/\s/g, "").length > 500 ? "text" : "ocr";
  if (source === "Desconocido" && mode === "ocr" && /estado[-_ ]de[-_ ]cuenta/i.test(file.name)) source = "Santander";
  onProgress(82, mode === "ocr" ? "El PDF requiere reconocimiento visual" : "Conciliando cargos y pagos");

  const periodMatch = text.match(/(?:Per[ií]odo de Facturaci[oó]n|PERIODO)\s*([^\n]{8,56})/i);
  const parsed = mode === "text" ? extractTransactions(text, source) : [];
  onProgress(100, "Listo para revisar");

  return {
    source,
    period: periodMatch?.[1]?.trim() ?? file.name.replace(/\.pdf$/i, ""),
    mode,
    transactions: parsed,
  };
}
