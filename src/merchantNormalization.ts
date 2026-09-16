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

const aliasRules = [
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
    .replace(/(?:^|\s)[\/#*;|]+(?=\s|$)/g, " ")
    .replace(/\s*[/;|]\s*$/g, "")
    .replace(/^\s*[/;|]+\s*/g, ""));
}

function displayCase(value: string) {
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

/**
 * Rappi merchant cleanup is intentionally conservative. The original text
 * remains available for evidence; only the rule/search identity is reduced.
 */
export function normalizeRappiMerchant(value: string): MerchantIdentity {
  const rawDescription = value.trim();
  const compactDescription = compact(rawDescription);
  const withoutTechnical = removeTechnicalFragments(compactDescription);
  const alias = aliasRules.find((rule) => rule.pattern.test(compactDescription));
  const normalizedMerchant = alias?.merchant ?? stableKey(withoutTechnical);
  const displayMerchant = alias?.display ?? displayCase(withoutTechnical || rawDescription);
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

export function merchantIdentityFor(value: string, source: string): MerchantIdentity {
  if (source === "Rappi" || /rappicard/i.test(source)) return normalizeRappiMerchant(value);
  const rawDescription = compact(value);
  return {
    rawDescription,
    normalizedMerchant: stableKey(rawDescription),
    displayMerchant: rawDescription,
    confidence: 1,
  };
}
