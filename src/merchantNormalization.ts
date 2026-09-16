export type MerchantIdentity = {
  rawDescription: string;
  normalizedMerchant: string;
  displayMerchant: string;
  confidence: number;
  reviewReason?: string;
};

const rappiCategoryRules: ReadonlyArray<{ category: string; pattern: RegExp }> = [
  // These are issuer-specific descriptors.  They are deliberately kept out
  // of the global taxonomy so a terse Rappi token cannot change the meaning
  // of an Amex, BBVA or Santander row.
  { category: "Software y suscripciones", pattern: /\b(?:google\s*cloud|apple(?:\s*com)?\s*bill)\b/ },
  { category: "Comisiones y finanzas", pattern: /\bswappedcom\b/ },
  { category: "Transporte", pattern: /\b(?:pase\s+recur|ado\s+web)\b/ },
  { category: "Salud", pattern: /\b(?:farm(?:acia|\s+san\s+pablo|\s+dr\s+ahorro|\s+guad)|f\s+ahorro|multifarmacias|dr\s+ismael)\b/ },
  { category: "Tiendita", pattern: /^(?:oxxo|7\s*eleven|7eleven)/ },
  { category: "Despensa / supermercado", pattern: /\b(?:sumesa|super\s+fasti|marcas\s+nestle|wildfork)\b/ },
  { category: "Deporte", pattern: /\b(?:decathlon|paddeo\s+sport|estadio\s+azul)\b/ },
  { category: "Entretenimiento", pattern: /\b(?:lucha\s+libre|cinetec|flix|pingpod|aerodiverti)\b/ },
  { category: "Viajes", pattern: /\b(?:avianca|ado\s+web)\b/ },
  { category: "Compras personales", pattern: /\b(?:shein|fraiche|juguete|bout\b|lib\s+rosario)\b/ },
  { category: "Restaurantes y bares", pattern: /\b(?:cafe|cafeteria|cafesitio|shake\s+shack|serena\s+horneando|los\s+gueros|tacos?|tortas?|crepas?|mcdonalds?|chili\s*s|casa\s*de\s*tono|maison\s+kayser|cevicheria|la\s+pancita|volovaneria|el\s+globo|fastfood|restaurant|rest\b|rest[a-z]{3,}|mezcaleria|barbacoa)\b|(?:cafeteria|cafesitio|mcdonalds?|sazonjarocho|tortasin|barbacoawtc|gajrest|resttonal|casadetono)/ },
];

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
// These prefixes identify the payment processor, not necessarily the actual
// merchant. Strip them only from the rule/search identity; rawDescription and
// the review evidence must keep the original token intact.
const processorPrefix = /^(?:merpago|mercadopago|payu|paypal|conekta|clip(?:\s+mx)?|bpk|d\s+local|pgb|com\s+rap)\s*[*:/-]?\s*/i;

function removeTechnicalFragments(value: string) {
  return compact(value
    .replace(technicalToken, " ")
    .replace(/(?:^|\s)[/#*;|]+(?=\s|$)/g, " ")
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
  const merchantCore = compact(withoutTechnical.replace(processorPrefix, ""));
  const processorDerived = merchantCore !== withoutTechnical;
  const alias = aliasRules.find((rule) => rule.pattern.test(compactDescription));
  const normalizedMerchant = alias?.merchant ?? stableKey(merchantCore);
  const displayMerchant = alias?.display ?? displayCase(merchantCore || rawDescription);
  const letters = (normalizedMerchant.match(/[a-z]{2,}/g) ?? []).join("");
  const noisy = (rawDescription.match(/[|*_#]{2,}/g) ?? []).length > 0;
  const tooLong = rawDescription.length > 100;
  const likelyOpaqueProcessorDescriptor = processorDerived
    && (/[0-9]/.test(merchantCore) || merchantCore.length < 4);
  const confidence = alias
    ? 0.96
    : !letters || tooLong
      ? 0.48
      : likelyOpaqueProcessorDescriptor || noisy
        ? 0.70
        : merchantCore.length >= 3
          ? 0.88
          : 0.58;
  const reviewReason = likelyOpaqueProcessorDescriptor
    ? "El texto conserva un identificador de procesador; confirma el comercio con la descripción original."
    : confidence < 0.75
    ? !letters
      ? "La descripción no conserva un nombre de comercio legible."
      : "El comercio conserva evidencia, pero la normalización no es suficientemente confiable."
    : undefined;
  return { rawDescription, normalizedMerchant, displayMerchant, confidence, reviewReason };
}

/**
 * Applies only high-signal Rappi category hints.  A processor descriptor such
 * as MERPAGO*... is intentionally absent: it may be readable while still not
 * proving the underlying merchant or its category.
 */
export function rappiCategoryFor(
  value: string,
  normalizedMerchant: string,
  flow: string,
  kind?: string,
) {
  if (flow !== "expense" || ["cardPayment", "bankTransfer", "income", "credit", "refund", "msi"].includes(kind ?? "")) {
    return undefined;
  }
  const text = fold(`${value} ${normalizedMerchant}`)
    .replace(/[^a-z0-9]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  return rappiCategoryRules.find((rule) => rule.pattern.test(text))?.category;
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
