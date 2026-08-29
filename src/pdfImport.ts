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

  // Scanned PDFs often have no text layer. Their filename is still useful
  // context, so expose a readable month/year instead of the raw slug.
  const normalizedFileName = fileName.normalize("NFD").replace(/[\u0300-\u036f]/g, "");
  const filePeriod = normalizedFileName.match(/(?:enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|setiembre|octubre|noviembre|diciembre|ene|feb|mar|abr|may|jun|jul|ago|sep|set|oct|nov|dic)[^\d]{0,8}(20\d{2})/i);
  if (filePeriod?.[0]) return filePeriod[0].replace(/[_-]+/g, " ").replace(/\s+/g, " ").trim();
  const numericPeriod = normalizedFileName.match(/20(\d{2})[-_. ](0?[1-9]|1[0-2])(?:\D|$)/);
  if (numericPeriod) return `${monthNames[Number(numericPeriod[2]) - 1]} 20${numericPeriod[1]}`;
  const reversedNumericPeriod = normalizedFileName.match(/(?:^|\D)(0?[1-9]|1[0-2])[-_. ]20(\d{2})(?:\D|$)/);
  if (reversedNumericPeriod) return `${monthNames[Number(reversedNumericPeriod[1]) - 1]} 20${reversedNumericPeriod[2]}`;

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
  const match = normalized.match(new RegExp(`(?:${label})[^\\d$-]{0,90}(-?\\s*\\$?(?:(?:\\d{1,3}(?:[ ,.\\u00a0]\\d{3})+|\\d+)(?:[.,]\\d{1,2})?))`, "i"));
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

  const normalized = text.normalize("NFD").replace(/[\u0300-\u036f]/g, "");
  const moneyToken = "(?:\\d{1,3}(?:[ ,.\\u00a0]\\d{3})+|\\d+)(?:[.,]\\d{1,2})?";
  const decimalMoneyToken = "(?<!\\d)(?:\\d{1,3}(?:[ ,.\\u00a0]\\d{3})+|\\d+)[.,]\\d{2}(?!\\d)";
  const parseToken = (value: string) => normalizeAmount(value.replace(/[^0-9,.-]/g, ""));
  const firstLabeledAmount = (label: string) => {
    const match = normalized.match(new RegExp(`(?:${label})(?![a-z])\\s*:?[^\\d$-]{0,32}(-?\\s*\\$?${moneyToken})`, "i"));
    return match?.[1] ? parseToken(match[1]) : undefined;
  };

  if (kind === "card") {
    // Amex prints the core balance as:
    // previous balance - payments/credits + new charges = statement balance minimum.
    const equation = normalized.match(new RegExp(`(${moneyToken})\\s*-\\s*(${moneyToken})\\s*\\+\\s*(${moneyToken})\\s*=\\s*(${moneyToken})\\s+(${moneyToken})`, "i"));
    if (equation) {
      summary.previousBalance = parseToken(equation[1]);
      summary.paymentsCredits = parseToken(equation[2]);
      summary.newCharges = parseToken(equation[3]);
      summary.statementBalance = parseToken(equation[4]);
      summary.paymentForNoInterest = parseToken(equation[4]);
      summary.minimumPayment = parseToken(equation[5]);
    }

    const newTransactions = firstLabeledAmount("nuevas transacciones|compras nuevas");
    if (newTransactions !== undefined) summary.newTransactions = newTransactions;
    const interest = firstLabeledAmount("inter[eé]s(?: financiero)?(?: del periodo)?");
    if (interest !== undefined) summary.interest = interest;
    const fees = firstLabeledAmount("comision(?:es)?");
    if (fees !== undefined) summary.fees = fees;

    // The transaction table is the reliable source for real card payments;
    // the equation only gives the combined "pagos y créditos" number.
    const paymentMatches = Array.from(normalized.matchAll(new RegExp(`gracias\\s+por\\s+su\\s+pago[^\\d$-]{0,32}(${moneyToken})`, "gi")))
      .map((match) => parseToken(match[1]))
      .filter((value) => value > 0);
    if (paymentMatches.length) {
      summary.payments = paymentMatches.reduce((total, value) => total + value, 0);
      if (summary.paymentsCredits !== undefined) {
        summary.credits = Math.max(0, summary.paymentsCredits - summary.payments);
      }
    }

    const creditSection = normalized.match(new RegExp(`limite\\s+de\\s+credito[\\s\\S]{0,220}?(${decimalMoneyToken})[\\s\\S]{0,70}?(${decimalMoneyToken})`, "i"));
    if (creditSection) {
      summary.creditLimit = parseToken(creditSection[1]);
      summary.creditAvailable = parseToken(creditSection[2]);
    }
  }
  return summary;
}

function guessCategory(description: string) {
  const value = normalizeText(description);
  const rules: Array<[string, RegExp]> = [
    ["Viajes", /airbnb|booking|expedia|hotel|hospedaje|aeromexico|aerobus|volaris|vivaaerobus|american airlines|united airlines|delta air|iberia|vuelo|flight|travel|renta de auto|car rental|airport|aeropuerto|equipaje|luggage/],
    ["Transporte", /uber|didi|cabify|taxi|metrobus|metrotap|nyct paygo|njtransit|nyc ferry|subway|mta |train |estacionamiento|estac |parking|parco |gasolina|pemex|shell|\bbp\b|gulf|mobil|caseta|autopista|toll|ecobici|mueve|transporte/],
    ["Salud", /farmacia|farmacias|hospital|clinica|doctor|consultorio|dent|dental|laboratorio|salud|medic/],
    ["Comidas", /restaurant|rest |rest\.|taquer|taco|sushi|cafe|coffee|starbucks|burger|pizza|pub|bar |comida|food|flauta|ramen|krispy|pan |pastel|helado|neveria|churro|frutos prohibidos|grill|deli|pantry|wine|beer|chicken|cocina|parrilla|guac time|chipotle|dos toros|dunkin|italian|crepes|sanborns|cerv|mariscos|exquisito|faunna|terraza|los gueros|guero|harp helu|serena horneando|tierra garat|malachy|sophie|lovejoy|smokejazz|smoke and gift|metropolis|mandarin mo|social|goldbergs|marta tap|hana group|tst\*|shreeji|jimmys|primavera|saio la octava|pickle|fogoncito|burger king|aifa|asador/],
    ["Alimentos", /walmart|superama|soriana|costco|chedraui|la comer|city market|sam'?s|sams |oxxo|7 eleven|seven eleven|extra k|extra |super |mercado\s|grocery|market|mkt |frutos|abarrotes|cvs|pharmacy|wholefds|whole foods|queens mkt|convenience|meadowland|mart corp|7-eleven/],
    ["Entretenimiento", /cinemex|cinepolis|cine |cinemas|teatro|spotify|netflix|disney|hbo|prime video|apple music|xbox|playstation|nintendo|steam|videojuego|club deportivo|entret |jazz|museum|museo|amnh|guggenheim|aquarium|acuario|zoo|attraction|atraccion|ticket|boletos|show|concierto|club |soccer|summit one|world of coca|circo|stadium|rounders|empire hall|hard rock|salon de perreo|asdeporte/],
    ["Educación", /universidad|escuela|colegio|curso|udemy|coursera|domestika|libros|libreria/],
    ["Mascotas", /veterin|petco|pet shop|mascota|mundo animal/],
    ["Hogar", /ikea|home depot|ferreter|muebles|hogar|limpieza|decoracion|mantenimiento/],
    ["Servicios", /canva|telcel|at&t|movistar|izzi|totalplay|cfe|luz |agua |internet|seguro|asegur|suscripcion|membresia|adobe|microsoft|google storage|apple\.com\/bill|apple\.com\/mx|paypal|stripe|holafly|wi-fi onboard|wifi onboard/],
    ["Compras", /amazon|shein|mercadolibre|mercado libre|mercadopago|lumen|steren|bout|tienda|shop|store|ropa|zapateria|departamental|old navy|fanatics|thriftland|miniso/],
    ["Finanzas", /comision|interes|cajero|retiro|anualidad|financ|keepcash|meses sin intereses|meses en automatico|meses automatico|monto a diferir|diferid/],
  ];
  const match = rules.find(([, marker]) => marker.test(value));
  if (match) return match[0];
  return "Sin categoría";
}

function inferImportedKind(description: string, amount: number, isCredit: boolean): TransactionKind {
  const value = normalizeText(description);
  if (/msi|meses sin intereses|meses en automatico|monto a diferir|diferir|diferid/.test(value)) return "msi";
  if (/interes|interes moratorio/.test(value)) return "interest";
  if (/comision|anualidad/.test(value)) return "fee";
  if (/devolucion|reembolso|bonificacion/.test(value) && amount > 0) return "refund";
  if (/gracias por su pago|pago en linea|pago.*(tarjeta|amex|credito)|tarjeta.*pago|american express/.test(value)) return "cardPayment";
  if (/transfer|traspaso/.test(value)) return "bankTransfer";
  if (isCredit || amount > 0) return "credit";
  return "purchase";
}

function extractTransactions(text: string, source: StatementSource, fileName: string, kind: StatementKind): Transaction[] {
  const lines = text.split(/\n+/).map((line) => line.replace(/\s+/g, " ").trim()).filter(Boolean);
  const results: Transaction[] = [];
  const datePattern = /^(?:(\d{1,2})\s+(?:de\s+)?(enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|setiembre|octubre|noviembre|diciembre|ene|feb|mar|abr|may|jun|jul|ago|sep|set|oct|nov|dic)(?:\s+(?:de\s+)?(\d{2,4}))?|(?:(\d{1,2})[-/.](\d{1,2})[-/.](\d{2,4}))|(?:(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})))/i;
  const amountPattern = /(?<![A-Za-z0-9])[-+]?\s*\$?(?:\d{1,3}(?:[ ,.\u00a0]\d{3})+(?:[.,]\d{1,2})?|\d+(?:[.,]\d{1,2})?)(?:\s*CR)?(?![A-Za-z0-9])/gi;
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

  // A PDF text layer may put the merchant, RFC/reference and amount on
  // separate lines. Reassemble each date-anchored row before extracting it.
  const rows: string[] = [];
  let pending = "";
  const breakPhrases = [
    "estado de cuenta", "fecha y detalle", "resumen de cuenta", "paga desde",
    "este no es un documento", "total de las transacciones", "total de transacciones",
    "total de movimientos", "periodo de facturacion", "fecha de corte", "pagina ",
  ];
  lines.forEach((line) => {
    const startsWithDate = datePattern.test(line);
    const normalized = normalizeText(line);
    const breaks = breakPhrases.some((phrase) => normalized.includes(phrase));
    if (startsWithDate) {
      if (pending) rows.push(pending);
      pending = line;
    } else if (pending && !breaks) {
      pending += ` ${line}`;
    } else if (breaks && pending) {
      rows.push(pending);
      pending = "";
    }
  });
  if (pending) rows.push(pending);

  rows.forEach((line, index) => {
    const date = line.match(datePattern);
    if (!date) return;
    const tail = line.slice(date[0].length).trim();
    const allCandidates = Array.from(tail.matchAll(amountPattern)).map((match) => ({
      raw: match[0],
      index: match.index ?? 0,
      value: normalizeAmount(match[0]),
    })).filter((candidate) => candidate.value !== 0 && Math.abs(candidate.value) < 100_000_000);
    // Prefer tokens that look like money. This prevents terminal numbers in
    // merchant names (store IDs, references and route numbers) from winning.
    const candidates = allCandidates.filter((candidate) => /[.,]\d{1,2}|\$|\bCR\b/i.test(candidate.raw));
    const usableCandidates = candidates.length ? candidates : allCandidates;
    if (!usableCandidates.length) return;
    const normalizedLine = normalizeText(line);
    const bankLike = kind === "bank" || /deposito|retiro|saldo|cuenta de cheques|cuenta de ahorro|abono|cargo/.test(normalizedLine);
    const foreignCurrency = /dolar|euro|peso colombiano|tipo de cambio|\btc\b/.test(normalizedLine);
    // Bank rows often finish with a running balance. Select the preceding
    // amount so the balance is not recorded as a purchase.
    const amount = foreignCurrency
      ? usableCandidates[0]
      : bankLike && usableCandidates.length > 1
        ? usableCandidates[usableCandidates.length - 2]
        : usableCandidates[usableCandidates.length - 1];
    const rawDescription = tail.slice(0, amount.index).trim();
    // Foreign Amex rows include currency and exchange-rate metadata before
    // the local amount. Keep the merchant name and discard that metadata.
    const description = rawDescription
      .replace(/\s+(?:d[oó]lar(?:es)?(?:\s+u\.s\.a\.)?|euro?s?|peso(?:s)?\s+colombiano?s?|tipo\s+de\s+cambio).*$/i, "")
      .replace(/\s+/g, " ")
      .trim();
    if (!description || description.length < 3) return;
    const normalizedDescription = normalizeText(description);
    const isRefund = /devolucion|reembolso|bonificacion/.test(normalizedDescription);
    const isCardPayment = /gracias por su pago|pago de tarjeta|pago.*(?:tarjeta|credito)|tarjeta.*pago/.test(normalizedDescription);
    const isIncome = /nomina|sueldo|salario|deposito|abono|ingreso|transferencia recibida/.test(normalizedDescription);
    const isTransfer = /transfer|traspaso|spei|entre cuentas|clabe/.test(normalizedDescription);
    const isCredit = /\bcr\b/i.test(amount.raw) || isRefund || isIncome;
    const flow: Transaction["flow"] = isRefund || isIncome ? "income" : isCardPayment ? "debt" : isTransfer ? "transfer" : "expense";
    const value = amount.value * (flow === "income" ? 1 : -1);
    const importedKind = inferImportedKind(description, value, isCredit);
    const category = importedKind === "cardPayment" || importedKind === "bankTransfer" ? "Transferencia" : guessCategory(description);
    const travelRelated = /viaje|hotel|hospedaje|aerolinea|vuelo|avion|transporte|uber|taxi|metro|renta de auto|destino|equipaje|airbnb|aeropuerto/i.test(normalizedDescription);
    results.push({
      id: `import-${importKey}-${index}-${value}`,
      date: formatDate(date),
      description: description.slice(0, 54),
      account: source,
      category,
      amount: value,
      flow,
      kind: importedKind,
      travelRelated,
      confidence: category === "Sin categoría" ? 0.62 : 0.92,
    });
  });

  // Do not silently drop valid rows from a busy month. The review UI limits
  // the visible page, but every parsed transaction remains available in the
  // ledger and can be refined later.
  return results;
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

  const parsed = mode === "text" ? extractTransactions(text, source, file.name, kind) : [];
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
