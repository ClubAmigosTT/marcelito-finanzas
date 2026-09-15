/**
 * Merchant identity used after extraction and before classification.
 *
 * The parser must keep the source description intact. This module therefore
 * returns three deliberately different values:
 * - rawDescription: the bounded text fragment as extracted from the row;
 * - normalizedMerchant: a stable key for rules and deduplication;
 * - displayMerchant: readable text for the user.
 */

export type MerchantIdentity = {
  rawDescription: string;
  normalizedMerchant: string;
  displayMerchant: string;
  confidence: number;
  reviewReason?: string;
};

function fold(value: string) {
  return value.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
}

function compact(value: string) {
  return value.replace(/\s+/g, " ").trim();
}

const aliasRules: Array<{ pattern: RegExp; merchant: string; display: string }> = [
  { pattern: /apple\s*[.*/]?\s*com\s*[./]?\s*bill/i, merchant: "apple", display: "Apple" },
  { pattern: /google\s*cloud|payu\s*\*?\s*google/i, merchant: "google cloud", display: "Google Cloud" },
  { pattern: /booking(?:\.com)?|flights\s+on\s+booking/i, merchant: "booking.com", display: "Booking.com" },
  { pattern: /viva\s*aero?bus|vivaaero?bus/i, merchant: "viva aerobus", display: "Viva Aerobus" },
  { pattern: /mta\s*\*?\s*lirr|lirr\s+station/i, merchant: "mta lirr station", display: "MTA LIRR Station" },
  { pattern: /mta\s*\*?\s*nyct\s*paygo/i, merchant: "mta nyct paygo", display: "MTA NYCT Paygo" },
  { pattern: /pase\s+recur/i, merchant: "pase", display: "PASE" },
  { pattern: /swappedcom/i, merchant: "swappedcom", display: "Swapped.com" },
  { pattern: /pago\s+por\s+spei/i, merchant: "pago por spei", display: "Pago por SPEI" },
];

const technicalToken = /\b(?:rfc|ref(?:erencia)?|folio|aut(?:orizaci[oó]n)?|operaci[oó]n|c[oó]digo|codigo|no\.?\s*de?)\s*[:#./_-]*\s*[a-z0-9-]+/gi;

function removeTechnicalFragments(value: string) {
  return compact(value
    .replace(technicalToken, " ")
    // These separators are only noise when they are left at a segment edge;
    // meaningful processor names and merchant symbols remain untouched.
    .replace(/(?:^|\s)[/#*;|]+(?=\s|$)/g, " ")
    .replace(/\s*[/;|]\s*$/g, "")
    .replace(/^\s*[/;|]+\s*/g, ""));
}

function displayCase(value: string) {
  // Preserve merchant punctuation and acronyms while making a fully-uppercase
  // OCR row easier to scan on a phone.
  if (!/[a-záéíóúüñ]/.test(value) && /[A-ZÁÉÍÓÚÜÑ]/.test(value)) {
    return value
      .toLocaleLowerCase("es-MX")
      .replace(/(^|[\s-])([a-záéíóúüñ])/g, (_, prefix: string, letter: string) => `${prefix}${letter.toLocaleUpperCase("es-MX")}`);
  }
  return value;
}

function stableKey(value: string) {
  return fold(value)
    .replace(technicalToken, " ")
    .replace(/[^a-z0-9]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/** Conservative Rappi merchant identity. Never truncates the raw text. */
export function normalizeRappiMerchant(value: string): MerchantIdentity {
  const rawDescription = value.trim();
  const compactDescription = compact(rawDescription);
  const withoutTechnical = removeTechnicalFragments(compactDescription);
  const alias = aliasRules.find((rule) => rule.pattern.test(compactDescription));
  const normalizedMerchant = alias?.merchant ?? stableKey(withoutTechnical);
  const displayMerchant = alias?.display ?? displayCase((withoutTechnical || rawDescription));
  const letters = (normalizedMerchant.match(/[a-z]{2,}/g) ?? []).join("");
  const noisy = (rawDescription.match(/[|*_#]{2,}/g) ?? []).length > 0;
  const tooLong = rawDescription.length > 100;
  const confidence = alias
    ? 0.96
    : !letters || tooLong
      ? 0.48
      : noisy
        ? 0.70
        : withoutTechnical.length >= 3
          ? 0.88
          : 0.58;
  const reviewReason = confidence < 0.75
    ? !letters
      ? "La descripción no conserva un nombre de comercio legible."
      : "El comercio conserva evidencia, pero la normalización no es suficientemente confiable."
    : undefined;
  return { rawDescription, normalizedMerchant, displayMerchant, confidence, reviewReason };
}

/** Fallback identity for issuers whose existing parser must remain unchanged. */
export function merchantIdentityFor(value: string, source: string) {
  if (source === "Rappi" || /rappicard/i.test(source)) return normalizeRappiMerchant(value);
  const rawDescription = compact(value);
  return {
    rawDescription,
    normalizedMerchant: stableKey(rawDescription),
    displayMerchant: rawDescription,
    confidence: 1,
  } satisfies MerchantIdentity;
}
