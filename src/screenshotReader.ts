import type {
  BalanceSnapshot,
  SourceDetection,
  ScreenshotParserId,
  StatementKind,
  StatementSource,
  Transaction,
  TransactionKind,
} from "./types.ts";
import { deterministicExpenseClassification } from "./categoryRules.ts";
import { normalizeConcept, parseDate } from "./reconciliation.ts";

/** Bumped whenever screenshot layout, OCR or normalization rules change. */
export const SCREENSHOT_READER_VERSION = "mobile-screenshot-reader-2026.09.09.2";

export type ScreenshotParseInput = {
  fileName: string;
  text: string;
  confidence?: number;
  sourceHint?: StatementSource;
  accountKey?: string;
  capturedAt?: string;
  imageIndex?: number;
};

export type ScreenshotParseResult = {
  source: StatementSource;
  sourceDetection: SourceDetection;
  accountKey?: string;
  kind: StatementKind;
  parserId: ScreenshotParserId;
  transactions: Transaction[];
  balanceSnapshots: BalanceSnapshot[];
  coverageStart?: string;
  coverageEnd?: string;
  warnings: string[];
  rejectedRowCount: number;
};

export type ScreenshotImportResult = ScreenshotParseResult & {
  fileNames: string[];
  sourceFingerprints: string[];
  readerVersion: typeof SCREENSHOT_READER_VERSION;
  capturedAt: string;
  averageConfidence: number;
};

const monthNames = "enero|ene|febrero|feb|marzo|mar|abril|abr|mayo|may|junio|jun|julio|jul|agosto|ago|septiembre|setiembre|sep|set|octubre|oct|noviembre|nov|diciembre|dic";
const weekdayNames = "lunes|martes|miercoles|miércoles|jueves|viernes|sabado|sábado|domingo";
const dateHeaderPattern = new RegExp(`(?:^|\\s)(?:${weekdayNames})?\\s*(\\d{1,2})\\s*(?:de\\s+)?(${monthNames})(?:\\s+(?:de\\s+)?(20\\d{2}))?(?:\\s|$)`, "i");
const moneyPattern = /(?<![A-Za-z0-9])(?:[-+]?\s*\$?\s*(?:\d{1,3}(?:[,.\s]\d{3})+|\d+)[.,]\d{2}|\$\s*[-+]?\s*(?:\d{1,3}(?:[,.\s]\d{3})+|\d+)[.,]\d{2})(?:\s*(?:MXN|M\.?N\.?))?(?![A-Za-z0-9])/gi;
const months: Record<string, number> = {
  ene: 1, enero: 1, feb: 2, febrero: 2, mar: 3, marzo: 3, abr: 4, abril: 4,
  may: 5, mayo: 5, jun: 6, junio: 6, jul: 7, julio: 7, ago: 8, agosto: 8,
  sep: 9, set: 9, septiembre: 9, setiembre: 9, oct: 10, octubre: 10,
  nov: 11, noviembre: 11, dic: 12, diciembre: 12,
};

function fold(value: string) {
  return value.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
}

function cleanLine(value: string) {
  return value.replace(/\s+/g, " ").trim();
}

function numberFromMoney(value: string) {
  let clean = value.replace(/[$\sA-Za-z]/g, "").trim();
  const comma = clean.lastIndexOf(",");
  const dot = clean.lastIndexOf(".");
  if (comma >= 0 && dot >= 0) {
    clean = comma > dot ? clean.replace(/\./g, "").replace(",", ".") : clean.replace(/,/g, "");
  } else if (comma >= 0) {
    const decimals = clean.length - comma - 1;
    clean = decimals <= 2 ? clean.replace(",", ".") : clean.replace(/,/g, "");
  }
  const parsed = Number(clean);
  return Number.isFinite(parsed) ? parsed : undefined;
}

/** Parses the last currency amount visible in a screenshot row. */
export function parseScreenshotMoney(value: string) {
  const matches = Array.from(value.matchAll(moneyPattern)).map((match) => match[0]);
  const raw = matches.at(-1);
  if (!raw) return undefined;
  const amount = numberFromMoney(raw);
  if (amount === undefined) return undefined;
  return {
    raw,
    amount: Math.abs(amount),
    explicitSign: /[-+]/.test(raw),
    negative: /-/.test(raw),
    positive: /\+/.test(raw),
  };
}

function yearFromInput(input: ScreenshotParseInput) {
  const explicit = input.text.match(/\b(20\d{2})\b/)?.[1];
  if (explicit) return Number(explicit);
  const capturedYear = input.capturedAt?.match(/^20\d{2}/)?.[0];
  return Number(capturedYear ?? new Date().getFullYear());
}

function dateFromHeader(line: string, year: number) {
  const match = line.match(dateHeaderPattern);
  if (!match) return undefined;
  const month = months[fold(match[2])] ?? months[fold(match[2]).slice(0, 3)];
  const day = Number(match[1]);
  const resolvedYear = match[3] ? Number(match[3]) : year;
  if (!month || !Number.isInteger(day) || day < 1 || day > 31) return undefined;
  const iso = `${resolvedYear}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
  return parseDate(iso) === undefined ? undefined : iso;
}

function dateBounds(values: string[]) {
  const timestamps = values.map((value) => ({ value, timestamp: parseDate(value) })).filter((item): item is { value: string; timestamp: number } => item.timestamp !== undefined);
  if (!timestamps.length) return {};
  timestamps.sort((left, right) => left.timestamp - right.timestamp);
  return { coverageStart: timestamps[0].value, coverageEnd: timestamps.at(-1)?.value };
}

function sourceDetection(input: ScreenshotParseInput): SourceDetection {
  const text = fold(`${input.text}\n${input.fileName}`);
  const institutional = text.split(/\r?\n/).slice(0, 16).join(" ");
  const candidates: Array<{ source: StatementSource; confidence: number; evidence: string[] }> = [];
  if (/\bmovimientos\b/.test(institutional) && (/\bmovimiento\s+bbva\b/.test(text) || /\bbbva\b/.test(institutional))) {
    candidates.push({ source: "BBVA", confidence: 0.995, evidence: ["encabezado Movimientos", "marca BBVA"] });
  }
  if (/super\s+nomina/.test(institutional) || (/saldo\s+actual/.test(institutional) && /santander/.test(text))) {
    candidates.push({ source: "Santander", confidence: 0.995, evidence: ["producto SUPER NOMINA", "saldo actual"] });
  }
  if (/american\s+express|the\s+platinum\s+credit\s+card/.test(institutional)) {
    candidates.push({ source: "Amex", confidence: 0.995, evidence: ["encabezado American Express"] });
  }
  const hinted = input.sourceHint && ["BBVA", "Santander", "Amex"].includes(input.sourceHint) ? input.sourceHint : undefined;
  const selected = hinted ? candidates.find((candidate) => candidate.source === hinted) ?? { source: hinted, confidence: 0.85, evidence: ["banco seleccionado por el usuario"] } : candidates[0];
  if (!selected || candidates.length > 1 && !hinted) {
    return { source: "Desconocido", confidence: 0, status: "unknown", evidence: candidates.length > 1 ? ["plantillas institucionales conflictivas"] : ["no se encontró un encabezado institucional suficiente"], ignoredBodyMentions: [] };
  }
  return { source: selected.source, confidence: selected.confidence, status: selected.confidence >= 0.99 ? "verified" : "review", evidence: selected.evidence, ignoredBodyMentions: [] };
}

function accountFromText(source: StatementSource, text: string, kind: StatementKind) {
  if (source === "Santander") {
    const match = text.match(/\b\d{1,2}\s*(?:[-*]\s*)?\*{2}\s*\d{4}\b/);
    const last4 = match?.[0].match(/\d{4}\s*$/)?.[0];
    return last4 ? `Santander:${kind}:${last4}` : undefined;
  }
  if (source === "Amex") {
    // The header is rendered as `....51003`, but OCR may turn the first dot
    // into `=` or insert a hyphen: `=..-51003`. Restrict the search to the
    // masked punctuation immediately following the Amex header so a date or
    // transaction amount cannot be mistaken for the card suffix.
    const last4 = text.match(/american\s+express[\s\S]{0,160}?(?:[-=._*•·]\s*){2,}(\d{4,5})/i)?.[1]?.slice(-4);
    return last4 ? `Amex:${kind}:${last4}` : undefined;
  }
  return undefined;
}

function stripLeadingUi(value: string) {
  // Do not strip generic non-word characters here: a leading minus sign is
  // the Santander/BBVA direction signal. Only remove OCR variants of the
  // timeline arrows and their punctuation.
  return value.replace(/^(?:[<>✓×»›←→↑↓]|[OVW]{1,2}\)(?=\s)|[OVW]{1,2}(?=\s))\s*/iu, "").trim();
}

function descriptionFromRow(value: string, moneyRaw: string) {
  return stripLeadingUi(value
    .replace(moneyRaw, " ")
    .replace(/\b(?:MXN|M\.?N\.?)\b/gi, " ")
    .replace(/\bpendiente\b/gi, " ")
    .replace(/\s*[>»›—–]+\s*$/u, " ")
    .replace(/\s+/g, " ")
    .trim());
}

function isTruncated(value: string) {
  return /(?:\.\.\.|…)$/.test(value.trim());
}

function amountDirection(description: string, money: NonNullable<ReturnType<typeof parseScreenshotMoney>>, defaultPositive = true) {
  if (money.negative) return { amount: -money.amount, inferred: false };
  if (money.positive) return { amount: money.amount, inferred: false };
  const text = fold(description);
  if (/recibid|deposito|abono|nomina|ingreso|credito|devolucion|reembolso|bonificacion/.test(text)) return { amount: money.amount, inferred: true };
  if (/enviad|retiro|cargo|comision|iva|pago|compra|transferencia\s+a\b/.test(text)) return { amount: -money.amount, inferred: true };
  return { amount: defaultPositive ? money.amount : -money.amount, inferred: true };
}

function kindForBank(description: string, amount: number): TransactionKind {
  const text = fold(description);
  if (/comision|iva/.test(text)) return "fee";
  if (/spei|transfer|traspaso|retiro/.test(text)) return "bankTransfer";
  return amount > 0 ? "income" : "purchase";
}

function isSantanderReferenceContinuation(value: string, previous?: Transaction): previous is Transaction {
  if (!previous || !/\brfc\b|^\d{4,}/i.test(previous.description)) return false;
  const text = value.replace(/[>»›,]+$/u, "").trim();
  return /\d/.test(text) && /^[a-z0-9?._-]{6,24}$/i.test(text);
}

function categoryFor(kind: TransactionKind, description: string, flow: Transaction["flow"]) {
  if (kind === "bankTransfer" || kind === "cardPayment") return { category: "Transferencia", classificationTags: undefined, merchantNormalized: undefined, confidence: 1, reason: "Tipo de movimiento detectado por el lector." };
  const classification = deterministicExpenseClassification(description, flow, kind);
  return classification
    ? { category: classification.category, classificationTags: classification.tags, merchantNormalized: classification.merchant, confidence: classification.confidence, reason: classification.reason }
    : { category: "Por revisar", classificationTags: undefined, merchantNormalized: normalizeConcept(description), confidence: 0.5, reason: "El concepto requiere clasificación." };
}

function makeScreenshotTransaction(options: {
  source: StatementSource;
  accountKey?: string;
  parserId: ScreenshotParserId;
  index: number;
  date: string;
  description: string;
  amount: number;
  kind: TransactionKind;
  status?: Transaction["captureStatus"];
  confidence: number;
  sourceText: string;
  imageIndex: number;
  capturedAt: string;
  inferredDirection?: boolean;
}) {
  const flow: Transaction["flow"] = options.kind === "cardPayment"
    ? "debt"
    : options.kind === "refund" || options.kind === "credit" || options.kind === "income"
      ? "income"
      : options.amount > 0 && options.kind === "bankTransfer"
        ? "income"
        : "expense";
  const classification = categoryFor(options.kind, options.description, flow);
  const confidence = Math.max(0, Math.min(1, options.confidence * (options.inferredDirection ? 0.82 : 1)));
  return {
    id: `${options.parserId}-${options.imageIndex}-${options.index + 1}`,
    date: options.date,
    description: options.description,
    displayDescription: options.description,
    descriptionTruncated: isTruncated(options.description),
    account: options.source,
    accountKey: options.accountKey,
    sourceType: "screenshot" as const,
    captureStatus: options.status ?? "displayed",
    observedAt: options.capturedAt,
    category: classification.category,
    amount: Math.round(options.amount * 100) / 100,
    flow,
    kind: options.kind,
    merchantNormalized: classification.merchantNormalized,
    normalizedDescription: normalizeConcept(options.description),
    classificationProvider: "rules" as const,
    classificationTags: classification.classificationTags,
    classificationConfidence: classification.confidence,
    classificationReason: classification.reason,
    confidence,
    validationStatus: options.inferredDirection || confidence < 0.75 ? "review" as const : "valid" as const,
    extractionEvidence: {
      method: "screenshot-ocr" as const,
      page: options.imageIndex + 1,
      confidence,
      sourceText: options.sourceText.slice(0, 300),
    },
  } satisfies Transaction;
}

function commonResult(input: ScreenshotParseInput, source: StatementSource, sourceEvidence: SourceDetection, parserId: ScreenshotParserId, kind: StatementKind, accountKey: string | undefined, transactions: Transaction[], balanceSnapshots: BalanceSnapshot[], warnings: string[], rejectedRowCount: number): ScreenshotParseResult {
  const dates = transactions.map((transaction) => transaction.date);
  const bounds = dateBounds(dates);
  return { source, sourceDetection: sourceEvidence, accountKey: input.accountKey ?? accountKey, kind, parserId, transactions, balanceSnapshots, ...bounds, warnings, rejectedRowCount };
}

function parseBBVA(input: ScreenshotParseInput, evidence: SourceDetection): ScreenshotParseResult {
  const lines = input.text.split(/\r?\n/).map(cleanLine).filter(Boolean);
  const year = yearFromInput(input);
  const transactions: Transaction[] = [];
  const warnings: string[] = [];
  let activeDate: string | undefined;
  let buffer: string[] = [];
  let pendingMoney: ReturnType<typeof parseScreenshotMoney>;
  let rejectedRowCount = 0;
  const flush = () => { buffer = []; };
  const rejectPending = () => {
    if (pendingMoney) rejectedRowCount += 1;
    pendingMoney = undefined;
  };
  const emit = (rowText: string, money: NonNullable<ReturnType<typeof parseScreenshotMoney>>) => {
    const description = descriptionFromRow(rowText, money.raw);
    if (description.length < 3 || /^(?:movimiento|ayuda|volver)$/i.test(description)) {
      rejectedRowCount += 1;
      return;
    }
    const direction = amountDirection(description, money);
    const kind = kindForBank(description, direction.amount);
    transactions.push(makeScreenshotTransaction({
      source: "BBVA",
      accountKey: input.accountKey,
      parserId: "bbva-mobile-screenshot-v1",
      index: transactions.length,
      date: activeDate as string,
      description,
      amount: direction.amount,
      kind,
      confidence: input.confidence ?? 0.9,
      sourceText: rowText,
      imageIndex: input.imageIndex ?? 0,
      capturedAt: input.capturedAt ?? new Date().toISOString(),
      inferredDirection: direction.inferred,
    }));
    if (isTruncated(description)) warnings.push(`BBVA: concepto truncado en "${description}"; se conservará tal como aparece.`);
  };
  lines.forEach((line) => {
    const date = dateFromHeader(line, year);
    if (date) {
      rejectPending();
      activeDate = date;
      flush();
      return;
    }
    if (!activeDate || /^(?:volv|ayuda|movimientos?|11:\d|\d{1,2}:\d{2}|ca\s+d|end)$/i.test(line) || /^movimiento\s+bbva$/i.test(line) || /transferencia interbancaria/.test(fold(line))) return;
    const money = parseScreenshotMoney(line);
    if (!money) {
      if (pendingMoney) {
        emit(cleanLine(`${line} ${pendingMoney.raw}`), pendingMoney);
        pendingMoney = undefined;
        return;
      }
      buffer.push(line);
      return;
    }
    if (buffer.length) {
      const rowText = cleanLine([...buffer, line].join(" "));
      flush();
      emit(rowText, money);
    } else {
      if (pendingMoney) rejectedRowCount += 1;
      pendingMoney = money;
    }
  });
  rejectPending();
  if (buffer.length) rejectedRowCount += 1;
  return commonResult(input, "BBVA", evidence, "bbva-mobile-screenshot-v1", "bank", undefined, transactions, [], Array.from(new Set(warnings)), rejectedRowCount);
}

function parseSantander(input: ScreenshotParseInput, evidence: SourceDetection): ScreenshotParseResult {
  const lines = input.text.split(/\r?\n/).map(cleanLine).filter(Boolean);
  const year = yearFromInput(input);
  const transactions: Transaction[] = [];
  const warnings: string[] = [];
  const balanceSnapshots: BalanceSnapshot[] = [];
  const accountKey = accountFromText("Santander", input.text, "bank");
  let activeDate: string | undefined;
  let buffer: string[] = [];
  let pendingMoney: ReturnType<typeof parseScreenshotMoney>;
  let rejectedRowCount = 0;
  let previousLine = "";
  let lastTransaction: Transaction | undefined;
  const flush = () => { buffer = []; };
  const rejectPending = () => {
    if (pendingMoney) rejectedRowCount += 1;
    pendingMoney = undefined;
  };
  const emit = (rowText: string, money: NonNullable<ReturnType<typeof parseScreenshotMoney>>) => {
    const description = descriptionFromRow(rowText, money.raw);
    if (description.length < 3 || /^(?:saldo actual|todos|pagos|gastos)$/i.test(description)) {
      rejectedRowCount += 1;
      return;
    }
    const direction = amountDirection(description, money, true);
    const kind = kindForBank(description, direction.amount);
    const transaction = makeScreenshotTransaction({
      source: "Santander",
      accountKey: input.accountKey ?? accountKey,
      parserId: "santander-mobile-screenshot-v1",
      index: transactions.length,
      date: activeDate as string,
      description,
      amount: direction.amount,
      kind,
      confidence: input.confidence ?? 0.88,
      sourceText: rowText,
      imageIndex: input.imageIndex ?? 0,
      capturedAt: input.capturedAt ?? new Date().toISOString(),
      inferredDirection: direction.inferred,
    });
    transactions.push(transaction);
    lastTransaction = transaction;
    if (direction.inferred) warnings.push(`Santander: dirección inferida para "${description}"; confirmar la flecha de entrada/salida.`);
    if (isTruncated(description)) warnings.push(`Santander: concepto truncado en "${description}"; se conservará tal como aparece.`);
  };
  lines.forEach((rawLine) => {
    const line = stripLeadingUi(rawLine);
    const date = dateFromHeader(line, year);
    if (date) {
      rejectPending();
      activeDate = date;
      flush();
      lastTransaction = undefined;
      return;
    }
    const balanceMoney = parseScreenshotMoney(previousLine);
    // Tesseract sometimes drops the first syllable in the Santander label
    // (`do actual` instead of `Saldo actual`). Only accept the OCR variant
    // when the preceding line also contains a money value.
    if (balanceMoney && /(?:saldo|do)\s+actual/i.test(line)) {
      balanceSnapshots.push({ accountKey: input.accountKey ?? accountKey, amount: balanceMoney.amount, currency: "MXN", capturedAt: input.capturedAt ?? new Date().toISOString(), extractionEvidence: { method: "screenshot-ocr", page: (input.imageIndex ?? 0) + 1, confidence: input.confidence ?? 0.9, sourceText: `${previousLine} ${line}`.slice(0, 300) } });
      previousLine = line;
      return;
    }
    previousLine = line;
    if (!activeDate || /^(?:super nomina|saldo actual|todos|pagos|gastos|compartir|ayuda|inicio|membresia|promociones|mi cuenta)$/i.test(line) || /^\d{1,2}\s*[-*]?\s*\*{2}\s*\d{4}$/.test(line) || /^\d{4}[-*]\d{4}$/.test(line)) return;
    const money = parseScreenshotMoney(line);
    if (!money) {
      if (isSantanderReferenceContinuation(line, lastTransaction)) {
        const previousTransaction = lastTransaction;
        const previousEvidence = previousTransaction.extractionEvidence ?? { method: "screenshot-ocr" as const, confidence: previousTransaction.confidence ?? 0.5 };
        const updated = {
          ...previousTransaction,
          description: cleanLine(`${previousTransaction.description} ${line}`),
          displayDescription: cleanLine(`${previousTransaction.displayDescription ?? previousTransaction.description} ${line}`),
          normalizedDescription: normalizeConcept(`${previousTransaction.description} ${line}`),
          extractionEvidence: {
            ...previousEvidence,
            sourceText: `${previousEvidence.sourceText ?? previousTransaction.description} ${line}`.slice(0, 300),
          },
        } satisfies Transaction;
        transactions[transactions.length - 1] = updated;
        lastTransaction = updated;
        return;
      }
      if (pendingMoney) {
        emit(cleanLine(`${line} ${pendingMoney.raw}`), pendingMoney);
        pendingMoney = undefined;
        return;
      }
      if (!/^(?:[a-z]{1,3}|\W+)$/i.test(line)) buffer.push(line);
      return;
    }
    if (buffer.length) {
      const rowText = cleanLine([...buffer, line].join(" "));
      flush();
      emit(rowText, money);
    } else {
      if (pendingMoney) rejectedRowCount += 1;
      pendingMoney = money;
    }
  });
  rejectPending();
  if (buffer.length) rejectedRowCount += 1;
  return commonResult(input, "Santander", evidence, "santander-mobile-screenshot-v1", "bank", accountKey, transactions, balanceSnapshots, Array.from(new Set(warnings)), rejectedRowCount);
}

function isAmexNoise(value: string) {
  const text = fold(value);
  return /^[a-z]$/.test(text) || /por referir|podras recibir|cashback|refiere amigos|inicio\b|membresia|promociones|mi cuenta|american express|servicio al cliente/.test(text);
}

function isAmexLocationContinuation(value: string) {
  const text = fold(value).replace(/[>»›—-]+$/u, "").trim();
  // Amex often places the city on a separate visual line. Sparse OCR can
  // emit that line after the amount, so attach only short, location-shaped
  // fragments and never an arbitrary next merchant name.
  if (/[*.]|https?:\/\//.test(text)) return false;
  return text.split(" ").length <= 5
    && /\b(?:mexic|mexico|ciudad|ju\?rez|juarez|tlalnepantla|benito|de)\b/.test(text);
}

function parseAmex(input: ScreenshotParseInput, evidence: SourceDetection): ScreenshotParseResult {
  const lines = input.text.split(/\r?\n/).map(cleanLine).filter(Boolean);
  const year = yearFromInput(input);
  const transactions: Transaction[] = [];
  const warnings: string[] = [];
  const accountKey = accountFromText("Amex", input.text, "card");
  let activeDate: string | undefined;
  let buffer: string[] = [];
  let candidate: { date: string; description: string; amount: number; raw: string; pending: boolean } | undefined;
  let pendingMoney: ReturnType<typeof parseScreenshotMoney>;
  let pendingAmountWasPending = false;
  let rejectedRowCount = 0;
  const flushCandidate = () => {
    if (!candidate) return;
    const normalized = fold(candidate.description);
    const isPayment = /gracias por su pago|pago en linea|pago de tarjeta/.test(normalized);
    const isRefund = /devolucion|reembolso|bonificacion|cashback/.test(normalized);
    const kind: TransactionKind = isPayment ? "cardPayment" : isRefund ? "refund" : "purchase";
    const amount = isPayment ? -candidate.amount : isRefund ? candidate.amount : -candidate.amount;
    transactions.push(makeScreenshotTransaction({
      source: "Amex",
      accountKey: input.accountKey ?? accountKey,
      parserId: "amex-mobile-screenshot-v1",
      index: transactions.length,
      date: candidate.date,
      description: candidate.description,
      amount,
      kind,
      status: candidate.pending ? "pending" : "displayed",
      confidence: input.confidence ?? 0.86,
      sourceText: candidate.raw,
      imageIndex: input.imageIndex ?? 0,
      capturedAt: input.capturedAt ?? new Date().toISOString(),
    }));
    if (isTruncated(candidate.description)) warnings.push(`Amex: concepto truncado en "${candidate.description}"; se conservará tal como aparece.`);
    candidate = undefined;
  };
  const flushBuffer = () => {
    if (buffer.length) rejectedRowCount += 1;
    buffer = [];
  };
  const rejectPending = () => {
    if (pendingMoney) rejectedRowCount += 1;
    pendingMoney = undefined;
    pendingAmountWasPending = false;
  };
  const makeCandidate = (description: string, money: NonNullable<ReturnType<typeof parseScreenshotMoney>>, pending = false) => {
    if (description.length < 3 || isAmexNoise(description)) {
      rejectedRowCount += 1;
      return;
    }
    candidate = {
      date: activeDate as string,
      description,
      amount: money.amount,
      raw: cleanLine(description + " " + money.raw),
      pending,
    };
  };
  lines.forEach((line) => {
    const date = dateFromHeader(line, year);
    if (date) {
      flushCandidate();
      rejectPending();
      flushBuffer();
      activeDate = date;
      return;
    }
    if (/^pendiente$/i.test(line)) {
      if (candidate) candidate.pending = true;
      else if (pendingMoney) pendingAmountWasPending = true;
      return;
    }
    if (!activeDate || isAmexNoise(line)) return;
    const money = parseScreenshotMoney(line);
    if (!money) {
      if (candidate) {
        if (isAmexLocationContinuation(line)) {
          const continuation = descriptionFromRow(line, "");
          candidate.description = cleanLine(`${candidate.description} ${continuation}`);
          candidate.raw = cleanLine(`${candidate.raw} ${continuation}`);
          return;
        }
        flushCandidate();
        buffer = [];
      }
      if (pendingMoney) {
        makeCandidate(descriptionFromRow(line + " " + pendingMoney.raw, pendingMoney.raw), pendingMoney, pendingAmountWasPending);
        pendingMoney = undefined;
        pendingAmountWasPending = false;
        return;
      }
      if (!/^(?:inicio|membresia|promociones|mi cuenta)$/i.test(line)) buffer.push(line);
      return;
    }
    if (candidate) flushCandidate();
    if (buffer.length) {
      const rowText = cleanLine([...buffer, line].join(" "));
      buffer = [];
      makeCandidate(descriptionFromRow(rowText, money.raw), money, /\bpendiente\b/i.test(rowText));
    } else {
      if (pendingMoney) rejectedRowCount += 1;
      const inlineDescription = descriptionFromRow(line, money.raw);
      if (inlineDescription.length >= 3 && !isAmexNoise(inlineDescription)) {
        makeCandidate(inlineDescription, money, /\bpendiente\b/i.test(line));
        pendingMoney = undefined;
        pendingAmountWasPending = false;
      } else {
        pendingMoney = money;
        pendingAmountWasPending = /\bpendiente\b/i.test(line);
      }
    }
  });
  flushCandidate();
  rejectPending();
  flushBuffer();
  if (lines.some((line) => new RegExp(`^\\d{1,2}\\s*(?:${monthNames})$`, "i").test(line))) warnings.push("Amex: el año se infirió a partir de la fecha de captura; revisar capturas cercanas a diciembre/enero.");
  return commonResult(input, "Amex", evidence, "amex-mobile-screenshot-v1", "card", accountKey, transactions, [], Array.from(new Set(warnings)), rejectedRowCount);
}

export function parseScreenshotText(input: ScreenshotParseInput): ScreenshotParseResult {
  const detection = sourceDetection(input);
  const source = detection.source;
  if (source === "BBVA") return parseBBVA(input, detection);
  if (source === "Santander") return parseSantander(input, detection);
  if (source === "Amex") return parseAmex(input, detection);
  throw new Error("No pudimos identificar BBVA, Santander o American Express en el screenshot.");
}

async function fingerprintFile(file: File) {
  const buffer = await file.arrayBuffer();
  if (globalThis.crypto?.subtle) {
    const digest = await globalThis.crypto.subtle.digest("SHA-256", buffer);
    return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
  }
  return `${file.name}:${file.size}:${file.lastModified}`;
}

function imageCanvas(file: File) {
  return new Promise<HTMLCanvasElement>((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const image = new Image();
    image.onload = () => {
      try {
        const longest = Math.max(image.naturalWidth, image.naturalHeight, 1);
        // Upscale phone captures enough for OCR, but also downscale very
        // large originals so a 12 MB camera image cannot allocate a huge
        // canvas before the per-file limit is reached.
        const scale = Math.max(0.35, Math.min(2.4, 2400 / longest));
        const canvas = document.createElement("canvas");
        canvas.width = Math.max(1, Math.round(image.naturalWidth * scale));
        canvas.height = Math.max(1, Math.round(image.naturalHeight * scale));
        const context = canvas.getContext("2d", { willReadFrequently: true });
        if (!context) throw new Error("No se pudo preparar la imagen para OCR.");
        context.imageSmoothingEnabled = true;
        context.imageSmoothingQuality = "high";
        context.drawImage(image, 0, 0, canvas.width, canvas.height);
        resolve(canvas);
      } catch (error) {
        reject(error);
      } finally {
        URL.revokeObjectURL(url);
      }
    };
    image.onerror = () => { URL.revokeObjectURL(url); reject(new Error("No se pudo abrir la imagen.")); };
    image.src = url;
  });
}

export async function inspectScreenshots(files: File[], options: { sourceHint?: StatementSource; accountKey?: string; capturedAt?: string; onProgress?: (value: number, label: string) => void } = {}): Promise<ScreenshotImportResult> {
  if (!files.length) throw new Error("Selecciona al menos un screenshot.");
  if (files.length > 20) throw new Error("Puedes importar hasta 20 screenshots por lote.");
  if (files.some((file) => file.size > 12 * 1024 * 1024)) throw new Error("Cada screenshot debe pesar menos de 12 MB.");
  const capturedAt = options.capturedAt ?? new Date().toISOString();
  const { createWorker } = await import("tesseract.js");
  const worker = await createWorker("spa", 1, {
    logger: ({ progress, status }) => options.onProgress?.(Math.round(Math.max(0, Math.min(1, progress)) * 90), status || "Reconociendo screenshot"),
  });
  try {
    const { PSM } = await import("tesseract.js");
    await worker.setParameters({ tessedit_pageseg_mode: PSM.SPARSE_TEXT, preserve_interword_spaces: "1" });
    const recognitionTimeoutMs = 45_000;
    const recognizeWithTimeout = async (canvas: HTMLCanvasElement) => {
      let timeoutId: ReturnType<typeof setTimeout> | undefined;
      try {
        return await Promise.race([
          worker.recognize(canvas, {}, { text: true }),
          new Promise<never>((_, reject) => {
            timeoutId = setTimeout(() => reject(new Error("El OCR tardó demasiado en un screenshot; intenta una imagen más ligera.")), recognitionTimeoutMs);
          }),
        ]);
      } finally {
        if (timeoutId !== undefined) clearTimeout(timeoutId);
      }
    };
    const parsed: ScreenshotParseResult[] = [];
    const fingerprints: string[] = [];
    for (const [index, file] of files.entries()) {
      if (!/^image\//i.test(file.type) && !/\.(?:jpe?g|png|webp|heic)$/i.test(file.name)) throw new Error(`El archivo ${file.name} no es una imagen compatible.`);
      const fingerprint = await fingerprintFile(file);
      fingerprints.push(fingerprint);
      const canvas = await imageCanvas(file);
      options.onProgress?.(Math.round(index / files.length * 90), `Leyendo screenshot ${index + 1} de ${files.length}`);
      const result = await recognizeWithTimeout(canvas);
      const confidence = Number(result.data.confidence) / 100;
      parsed.push(parseScreenshotText({ fileName: file.name, text: result.data.text, confidence: Number.isFinite(confidence) ? confidence : 0.5, sourceHint: options.sourceHint, accountKey: options.accountKey, capturedAt, imageIndex: index }));
      canvas.width = 0;
      canvas.height = 0;
    }
    const sources = Array.from(new Set(parsed.map((item) => item.source)));
    if (sources.length !== 1 || sources[0] === "Desconocido") throw new Error("Un lote de screenshots debe pertenecer al mismo banco o tarjeta.");
    const first = parsed[0];
    const transactions = parsed.flatMap((item) => item.transactions);
    const balances = parsed.flatMap((item) => item.balanceSnapshots);
    const dates = dateBounds(transactions.map((transaction) => transaction.date));
    const warnings = Array.from(new Set(parsed.flatMap((item) => item.warnings)));
    const averageConfidence = parsed.length ? parsed.reduce((sum, item) => sum + (item.transactions.length ? item.transactions.reduce((total, transaction) => total + (transaction.confidence ?? 0), 0) / item.transactions.length : 0), 0) / parsed.length : 0;
    options.onProgress?.(100, "Screenshots listos para revisar");
    return {
      ...first,
      fileNames: files.map((file) => file.name),
      sourceFingerprints: fingerprints,
      readerVersion: SCREENSHOT_READER_VERSION,
      capturedAt,
      transactions,
      balanceSnapshots: balances,
      ...dates,
      warnings,
      rejectedRowCount: parsed.reduce((sum, item) => sum + item.rejectedRowCount, 0),
      averageConfidence,
    };
  } finally {
    await worker.terminate();
  }
}
