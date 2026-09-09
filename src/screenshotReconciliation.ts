import type { ScreenshotCapture, Statement, Transaction } from "./types.ts";
import { isStatementEligibleForDashboard } from "./finance.ts";
import { normalizeConcept, parseDate } from "./reconciliation.ts";

const dayMs = 24 * 60 * 60 * 1000;

function fold(value: string) {
  return value.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
}

function identityText(value: string) {
  return fold(value).replace(/[^a-z0-9]+/g, " ").trim();
}

function accountParts(value: string) {
  const normalized = identityText(value);
  const digits = normalized.match(/(\d{4})$/)?.[1];
  const source = normalized.split(" ")[0] ?? "";
  const kind = normalized.split(" ").find((part) => part === "bank" || part === "card" || part === "unknown");
  return { source: /[a-z]/.test(source) ? source : "", kind, digits };
}

function sameAccountIdentity(left: string, right: string) {
  if (identityText(left) === identityText(right)) return true;
  const leftParts = accountParts(left);
  const rightParts = accountParts(right);
  if (!leftParts.digits || !rightParts.digits || leftParts.digits !== rightParts.digits) return false;
  if (leftParts.kind && rightParts.kind && leftParts.kind !== rightParts.kind) return false;
  return !leftParts.source || !rightParts.source || leftParts.source === rightParts.source;
}

function sourceFor(transaction: Transaction, statements: Statement[]) {
  const statement = transaction.statementId ? statements.find((item) => item.id === transaction.statementId) : undefined;
  return statement?.source ?? transaction.account;
}

function kindFor(transaction: Transaction, statements: Statement[]) {
  const statement = transaction.statementId ? statements.find((item) => item.id === transaction.statementId) : undefined;
  return statement?.kind ?? (transaction.accountKey?.includes(":card:") ? "card" : transaction.accountKey?.includes(":bank:") ? "bank" : undefined);
}

/**
 * Returns the safest account identity available without inventing one. A
 * masked suffix is preferred; otherwise an issuer + product fallback keeps
 * different banks/cards apart while still allowing old imports to match.
 */
export function transactionAccountIdentity(transaction: Transaction, statements: Statement[]) {
  if (transaction.accountKey) return transaction.accountKey;
  const statement = transaction.statementId ? statements.find((item) => item.id === transaction.statementId) : undefined;
  if (statement?.accountKey) return statement.accountKey;
  const source = sourceFor(transaction, statements);
  const kind = kindFor(transaction, statements) ?? "unknown";
  return `${source}:${kind}`;
}

function normalizedDate(transaction: Transaction, statements: Statement[]) {
  const statement = transaction.statementId ? statements.find((item) => item.id === transaction.statementId) : undefined;
  const timestamp = parseDate(transaction.date, statement?.period);
  if (timestamp === undefined) return fold(transaction.date).replace(/\s+/g, " ").trim();
  return new Intl.DateTimeFormat("en-CA", { year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(timestamp));
}

/** Stable identity for screenshot observations; status is intentionally omitted. */
export function screenshotDeduplicationKey(transaction: Transaction, statements: Statement[] = []) {
  const account = identityText(transactionAccountIdentity(transaction, statements)) || "cuenta-desconocida";
  const date = normalizedDate(transaction, statements);
  const amount = Math.round(Math.abs(transaction.amount) * 100).toString();
  const description = normalizeConcept(transaction.displayDescription || transaction.description);
  const kind = transaction.kind ?? "other";
  return [account, date, amount, description, kind].join("|");
}

function screenshotDuplicateBase(transaction: Transaction, statements: Statement[] = []) {
  const account = identityText(transactionAccountIdentity(transaction, statements)) || "cuenta-desconocida";
  const date = normalizedDate(transaction, statements);
  const amount = Math.round(Math.abs(transaction.amount) * 100).toString();
  const kind = transaction.kind ?? "other";
  return [account, date, amount, kind].join("|");
}

function sameCaptureImage(left: Transaction, right: Transaction) {
  if (left.sourceCaptureId && right.sourceCaptureId && left.sourceCaptureId !== right.sourceCaptureId) return false;
  const leftPage = left.extractionEvidence?.page;
  const rightPage = right.extractionEvidence?.page;
  return leftPage !== undefined && rightPage !== undefined && leftPage === rightPage;
}

/**
 * Marks repeated observations but never deletes the raw row. Two identical
 * rows on the same image are retained because they can be two real purchases;
 * the same row on another image/capture is marked as an overlap duplicate.
 */
export function deduplicateScreenshotTransactions(transactions: Transaction[], statements: Statement[] = []) {
  const seen = new Map<string, Transaction[]>();
  const next = transactions.map((transaction) => {
    const key = screenshotDeduplicationKey(transaction, statements);
    const previous = seen.get(key) ?? [];
    const allPrevious = [...seen.values()].flat();
    const matchesObservation = (candidate: Transaction) => screenshotDeduplicationKey(candidate, statements) === key
      || screenshotDuplicateBase(candidate, statements) === screenshotDuplicateBase(transaction, statements)
        && descriptionSimilarity(candidate, transaction) >= 0.75;
    // If the same screenshot image contains two identical rows, retain both:
    // they may be two legitimate purchases. An overlap from another image is
    // a duplicate only when this image has not already established that pair.
    const hasSameImageObservation = allPrevious.some((candidate) => sameCaptureImage(candidate, transaction) && matchesObservation(candidate));
    const duplicate = hasSameImageObservation ? undefined : allPrevious.find((candidate) => !sameCaptureImage(candidate, transaction) && matchesObservation(candidate));
    const marked = duplicate
      ? { ...transaction, duplicateOf: duplicate.id }
      : { ...transaction, duplicateOf: undefined };
    seen.set(key, [...previous, marked]);
    return marked;
  });
  return {
    transactions: next,
    canonical: next.filter((transaction) => !transaction.duplicateOf),
    duplicateCount: next.filter((transaction) => Boolean(transaction.duplicateOf)).length,
  };
}

function timestampFor(transaction: Transaction, statements: Statement[]) {
  const statement = transaction.statementId ? statements.find((item) => item.id === transaction.statementId) : undefined;
  return parseDate(transaction.date, statement?.period);
}

function tokenSet(value: string) {
  return new Set(normalizeConcept(value).split(" ").filter((token) => token.length >= 3));
}

function descriptionSimilarity(left: Transaction, right: Transaction) {
  const leftText = normalizeConcept(left.displayDescription || left.description);
  const rightText = normalizeConcept(right.displayDescription || right.description);
  if (!leftText || !rightText) return 0;
  if (leftText === rightText) return 1;
  if (leftText.includes(rightText) || rightText.includes(leftText)) return 0.88;
  const leftTokens = tokenSet(leftText);
  const rightTokens = tokenSet(rightText);
  const intersection = [...leftTokens].filter((token) => rightTokens.has(token)).length;
  const union = new Set([...leftTokens, ...rightTokens]).size;
  return union ? intersection / union : 0;
}

type Candidate = {
  transaction: Transaction;
  score: number;
  reason: string;
  dayDistance: number;
};

function candidateFor(screenshot: Transaction, official: Transaction, statements: Statement[]): Candidate | undefined {
  const screenshotSource = fold(sourceFor(screenshot, statements));
  const officialSource = fold(sourceFor(official, statements));
  if (!screenshotSource || screenshotSource !== officialSource) return undefined;

  const screenshotAccount = transactionAccountIdentity(screenshot, statements);
  const officialAccount = transactionAccountIdentity(official, statements);
  if (!screenshot.accountKey) {
    const accountIdentities = new Set(
      statements
        .filter((statement) => fold(statement.source) === screenshotSource && statement.accountKey)
        .map((statement) => statement.accountKey),
    );
    // A source-only screenshot cannot safely choose between two masked
    // accounts from the same issuer. It remains reviewable until the user
    // supplies the account identity or an official statement narrows it.
    if (accountIdentities.size > 1) return undefined;
  }
  // If both sides carry a masked identity, never cross-match accounts.
  if (screenshot.accountKey && !sameAccountIdentity(officialAccount, screenshotAccount)) return undefined;

  const amountDistance = Math.abs(Math.abs(screenshot.amount) - Math.abs(official.amount));
  if (amountDistance > 0.01) return undefined;
  const screenshotDate = timestampFor(screenshot, statements);
  const officialDate = timestampFor(official, statements);
  if (screenshotDate === undefined || officialDate === undefined) return undefined;
  const dayDistance = Math.abs(screenshotDate - officialDate) / dayMs;
  if (dayDistance > 5) return undefined;

  const description = descriptionSimilarity(screenshot, official);
  const datePoints = dayDistance === 0 ? 25 : dayDistance <= 1 ? 21 : dayDistance <= 3 ? 14 : 8;
  const descriptionPoints = description >= 0.99 ? 25 : description >= 0.75 ? 20 : description >= 0.45 ? 12 : 0;
  const sourcePoints = screenshot.accountKey && official.accountKey ? 10 : 5;
  const score = 50 + datePoints + descriptionPoints + sourcePoints;
  if (descriptionPoints === 0) return { transaction: official, score, reason: "importe y fecha compatibles; concepto diferente", dayDistance };
  return {
    transaction: official,
    score,
    reason: ["importe exacto", dayDistance === 0 ? "misma fecha" : `${Math.round(dayDistance)} día(s) de diferencia`, description >= 0.99 ? "concepto exacto" : "concepto compatible"].join(" · "),
    dayDistance,
  };
}

function officialAppliesToCapture(capture: ScreenshotCapture, official: Transaction, statements: Statement[]) {
  if (fold(sourceFor(official, statements)) !== fold(capture.source)) return false;
  if (capture.accountKey && !sameAccountIdentity(transactionAccountIdentity(official, statements), capture.accountKey)) return false;
  return true;
}

function captureStats(capture: ScreenshotCapture, transactions: Transaction[], officialPresent: boolean): ScreenshotCapture {
  const deduplicated = transactions.filter((transaction) => !transaction.duplicateOf);
  const matchedCount = deduplicated.filter((transaction) => Boolean(transaction.matchedTransactionId)).length;
  const readerReviewCount = deduplicated.filter((transaction) => transaction.validationStatus === "review" || (transaction.confidence ?? 1) < 0.75).length;
  const unmatchedCount = officialPresent ? deduplicated.filter((transaction) => !transaction.matchedTransactionId).length : 0;
  const reviewCount = readerReviewCount + unmatchedCount;
  const status = !officialPresent
    ? readerReviewCount ? "review" : "provisional"
    : matchedCount === deduplicated.length && deduplicated.length > 0
      ? "reconciled"
      : matchedCount > 0
        ? "partially-reconciled"
        : "review";
  return {
    ...capture,
    transactions,
    transactionCount: transactions.length,
    duplicateCount: transactions.filter((transaction) => Boolean(transaction.duplicateOf)).length,
    matchedCount,
    reviewCount,
    status,
  };
}

/** Recalculates overlap markers across all stored screenshot batches. */
export function deduplicateScreenshotCaptures(captures: ScreenshotCapture[], statements: Statement[] = []) {
  const all = captures.flatMap((capture) => capture.transactions);
  const result = deduplicateScreenshotTransactions(all, statements);
  let offset = 0;
  return captures.map((capture) => {
    const count = capture.transactions.length;
    const transactions = result.transactions.slice(offset, offset + count);
    offset += count;
    return captureStats(capture, transactions, false);
  });
}

/**
 * Links a provisional screenshot row to one official statement row. The
 * screenshot remains in the audit trail; the official row stays authoritative.
 */
export function reconcileScreenshotCaptures(captures: ScreenshotCapture[], officialTransactions: Transaction[], statements: Statement[]) {
  const officialIds = new Set<string>();
  const availableOfficial = officialTransactions.filter((transaction) => {
    if (transaction.sourceType === "screenshot" || !transaction.statementId || transaction.validationStatus === "invalid") return false;
    const statement = statements.find((item) => item.id === transaction.statementId);
    // A provisional/rejected PDF is not allowed to confirm a screenshot. This
    // keeps the two quality gates aligned: official rows can only be evidence
    // after the same statement is eligible for dashboard use.
    return Boolean(statement && isStatementEligibleForDashboard(statement));
  });
  const next = captures.map((capture) => {
    const local = capture.transactions.map((transaction) => {
      if (transaction.duplicateOf) return transaction;
      const candidates = availableOfficial
        .filter((official) => !officialIds.has(official.id))
        .map((official) => candidateFor(transaction, official, statements))
        .filter((candidate): candidate is Candidate => Boolean(candidate))
        .sort((left, right) => right.score - left.score || left.dayDistance - right.dayDistance);
      const best = candidates[0];
      const second = candidates[1];
      // Exact concept matches can safely confirm at 90+. A merely equal
      // amount/date row needs a unique edge with a lower bound to avoid false
      // confirmations when a card has repeated purchases of the same amount.
      const unique = Boolean(best && (!second || best.score - second.score >= 8));
      const confirmed = Boolean(best && unique && best.score >= 85);
      if (!confirmed || !best) {
        return {
          ...transaction,
          matchedTransactionId: undefined,
          reconciliationConfidence: undefined,
          reconciliationReason: best ? "Hay una coincidencia posible, pero requiere revisión manual." : "Aún no hay un movimiento oficial compatible.",
          captureStatus: best ? "review" as const : transaction.captureStatus === "pending" ? "pending" as const : "review" as const,
        };
      }
      officialIds.add(best.transaction.id);
      return {
        ...transaction,
        matchedTransactionId: best.transaction.id,
        reconciliationConfidence: Math.min(0.99, best.score / 100),
        reconciliationReason: best.reason,
        captureStatus: "confirmed" as const,
      };
    });
    const officialPresentForCapture = availableOfficial.some((official) => officialAppliesToCapture(capture, official, statements));
    return captureStats(capture, local, officialPresentForCapture);
  });
  return next;
}

export function screenshotCanonicalTransactions(captures: ScreenshotCapture[]) {
  return captures.flatMap((capture) => capture.transactions.filter((transaction) => !transaction.duplicateOf));
}
