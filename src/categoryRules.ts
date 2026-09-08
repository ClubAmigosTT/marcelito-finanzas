import type { ExpenseTag, FlowType, TransactionKind } from "./types.ts";
export type { ExpenseTag } from "./types.ts";

/** Stable primary categories; orthogonal dimensions are represented as tags. */
export const expenseCategories = [
  "Restaurantes y bares",
  "Tiendita",
  "Despensa / supermercado",
  "Entretenimiento",
  "Viajes",
  "Transporte",
  "Deporte",
  "Compras personales",
  "Software y suscripciones",
  "Salud",
  "Club Amigos / Proyectos",
  "Comisiones y finanzas",
  "Otros / Por revisar",
] as const;

export type ExpenseCategory = typeof expenseCategories[number];

export const expenseTags = [
  "viaje",
  "ordinario",
  "extraordinario",
  "fijo",
  "variable",
  "personal",
  "proyecto",
] as const;

export type DeterministicExpenseClassification = {
  category: ExpenseCategory;
  merchant: string;
  tags: ExpenseTag[];
  confidence: number;
  reason: string;
};

/** A stable, privacy-preserving key for a merchant correction. */
export function merchantKey(description: string) {
  return description
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/\b(?:rfc|ref|referencia|aut)\s*[a-z0-9_-]+/g, " ")
    .replace(/\b\d{2,}\b/g, " ")
    .replace(/[^a-z0-9]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 96);
}

export type CategoryRules = Record<string, string>;

export function categoryFromRules(description: string, rules: CategoryRules) {
  const key = merchantKey(description);
  return key ? rules[key] : undefined;
}

function normalizedDescription(description: string) {
  return description
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function containsAny(text: string, markers: readonly string[]) {
  const padded = ` ${text} `;
  return markers.some((marker) => {
    const normalizedMarker = normalizedDescription(marker);
    if (!normalizedMarker) return false;
    // Exact tokens prevent short merchants such as "Extra" from matching
    // words like "extraordinario". Longer stems still support bank truncation
    // such as "taquer" in "taquería".
    return padded.includes(` ${normalizedMarker} `)
      || (normalizedMarker.length >= 6 && text.includes(normalizedMarker));
  });
}

function merchantLabel(description: string) {
  const label = description
    .replace(/\s+/g, " ")
    .replace(/\b(?:aut\.?|ref\.?|folio|no\.?|num\.?)[\s:#-]*[a-z0-9-]+/gi, "")
    .trim();
  return (label || "Sin descripción").slice(0, 80);
}

const projectMarkers = ["club amigos", "clubamigos", "proyecto", "proveedor club", "material club"] as const;
const financeMarkers = ["comision", "interes", "iva com", "cargo bancario", "cajero", "anualidad", "seguro financiero", "financiera", "finanzas"] as const;
const softwareMarkers = ["canva", "cursor", "google one", "google storage", "youtube premium", "apple music", "adobe", "microsoft 365", "microsoft office", "suscripcion", "suscripción", "saas", "software", "icloud", "dropbox", "apple com bill", "apple com mx"] as const;
const travelMarkers = ["airbnb", "booking", "expedia", "hotel", "hospedaje", "aeromexico", "aerobus", "volaris", "vivaaerobus", "american airlines", "united airlines", "delta air", "iberia", "vuelo", "flight", "holafly", "esim", "roaming", "equipaje", "airport", "aeropuerto", "renta de auto", "car rental", "nueva york", "new york", "medellin", "medellín", "atlanta"] as const;
const entertainmentMarkers = ["cinemex", "cinemas wtc", "cinepolis", "cine", "teatro", "museo", "museum", "moma", "guggenheim", "summit one", "concierto", "festival", "boleto", "ticket", "show", "smoke jazz", "jazz", "nekoma", "club nocturno", "experiencia", "ocio"] as const;
const sportMarkers = ["club deportivo", "club deportivo kanoa", "asdeporte", "pickleball", "padel", "pádel", "cancha", "renta de cancha", "gimnasio", "gym", "deporte", "competencia"] as const;
const healthMarkers = ["farmacia", "farmacias", "hospital", "clinica", "clínica", "doctor", "consultorio", "dentista", "dental", "odont", "laboratorio", "salud", "medic", "medico", "medical", "tratamiento"] as const;
const restaurantMarkers = ["restaurant", "rest ", "taquer", "taco", "sushi", "cafe", "coffee", "starbucks", "burger", "pizza", "pub", "bar ", "comida", "food", "delivery", "rappi", "didi food", "flauta", "ramen", "italian", "crepes", "cerv", "mariscos", "grill", "cocina", "parrilla", "chipotle", "doordash", "ubereats", "uber eats", "casa de tono", "espeto", "japiramen", "orinoco", "waffles"] as const;
const convenienceMarkers = ["oxxo", "7 eleven", "seven eleven", "7-eleven", "extra", "circle k", "minisuper", "mini super", "tienda de conveniencia", "convenience store", "snack", "abarrotes pequeno"] as const;
const groceryMarkers = ["walmart", "superama", "soriana", "costco", "chedraui", "la comer", "city market", "sam s", "sams ", "supermercado", "grocery", "whole foods", "wholefds", "despensa", "abarrotes", "mercado grande"] as const;
const transportMarkers = ["uber", "didi", "cabify", "taxi", "metrobus", "metro ", "metrotap", "nyct", "nj transit", "njtransit", "nyc ferry", "subway", "mta ", "train ", "estacionamiento", "parking", "parco ", "gasolina", "pemex", "shell", "bp ", "gulf", "mobil", "caseta", "autopista", "toll", "ecobici", "transporte", "movilidad"] as const;
const personalShoppingMarkers = ["apple", "shein", "amazon", "sanborns", "miniso", "old navy", "mercadolibre", "mercado libre", "mercadopago", "lumen", "steren", "boutique", "tienda", "shop", "store", "ropa", "zapateria", "departamental", "electronic", "electronico", "accesorio", "compras"] as const;
const recurringMarkers = [...softwareMarkers, "renta", "telcel", "at&t", "movistar", "izzi", "totalplay", "cfe", "luz ", "agua ", "internet", "seguro", "membresia", "membresía"] as const;

/** Deterministic first pass; weak descriptors stay in the review bucket. */
export function deterministicExpenseClassification(
  description: string,
  flow: FlowType = "expense",
  kind: TransactionKind | undefined = "purchase",
): DeterministicExpenseClassification | undefined {
  if (flow !== "expense" || ["cardPayment", "bankTransfer", "income", "credit", "refund", "msi"].includes(kind ?? "other")) return undefined;
  const text = normalizedDescription(description);
  const merchant = merchantLabel(description);
  const project = containsAny(text, projectMarkers);
  let category: ExpenseCategory = "Otros / Por revisar";
  let reason = "El descriptor no permite identificar la naturaleza del gasto con suficiente seguridad.";
  let confidence = 0.35;

  // Project identity is explicitly higher priority than a merchant's usual use.
  if (project) {
    category = "Club Amigos / Proyectos";
    reason = "El concepto identifica un gasto de proyecto.";
    confidence = 0.98;
  } else if (containsAny(text, financeMarkers)) {
    category = "Comisiones y finanzas";
    reason = "El concepto describe un costo financiero o bancario.";
    confidence = 0.96;
  } else if (containsAny(text, softwareMarkers)) {
    category = "Software y suscripciones";
    reason = "El concepto corresponde a una herramienta o suscripción digital.";
    confidence = 0.95;
  } else if (containsAny(text, travelMarkers)) {
    category = "Viajes";
    reason = "El concepto corresponde a transporte de larga distancia, hospedaje o servicio de viaje.";
    confidence = 0.96;
  } else if (containsAny(text, entertainmentMarkers)) {
    category = "Entretenimiento";
    reason = "El concepto corresponde a ocio, espectáculo o experiencia recreativa.";
    confidence = 0.94;
  } else if (containsAny(text, sportMarkers)) {
    category = "Deporte";
    reason = "El concepto corresponde a práctica deportiva, club o instalación deportiva.";
    confidence = 0.95;
  } else if (containsAny(text, healthMarkers)) {
    category = "Salud";
    reason = "El concepto corresponde a un servicio médico, dental o farmacéutico.";
    confidence = 0.95;
  } else if (containsAny(text, restaurantMarkers)) {
    category = "Restaurantes y bares";
    reason = "El concepto identifica comida o bebida preparada para consumo inmediato.";
    confidence = 0.94;
  } else if (containsAny(text, convenienceMarkers)) {
    category = "Tiendita";
    reason = "El concepto identifica una tienda de conveniencia o compra pequeña de paso.";
    confidence = 0.96;
  } else if (containsAny(text, groceryMarkers)) {
    category = "Despensa / supermercado";
    reason = "El concepto identifica una compra grande de despensa o supermercado.";
    confidence = 0.94;
  } else if (containsAny(text, transportMarkers)) {
    category = "Transporte";
    reason = "El concepto identifica movilidad local o estacionamiento.";
    confidence = 0.93;
  } else if (containsAny(text, personalShoppingMarkers)) {
    category = "Compras personales";
    reason = "El concepto identifica bienes de consumo personal o compra general.";
    confidence = 0.88;
  }

  const tags: ExpenseTag[] = [];
  tags.push(project ? "proyecto" : "personal");
  const travel = category === "Viajes" || containsAny(text, travelMarkers);
  if (travel) tags.push("viaje");
  const fixed = containsAny(text, recurringMarkers);
  tags.push(fixed ? "fijo" : "variable");
  const extraordinary = travel || category === "Entretenimiento" || containsAny(text, ["evento", "concierto", "festival", "emergencia", "reparacion", "reparación"]);
  tags.push(extraordinary ? "extraordinario" : "ordinario");
  return { category, merchant, tags, confidence, reason };
}

/** True when a row may be sent to the optional classifier. */
export function isClassifiableExpense(flow: FlowType, kind: TransactionKind | undefined) {
  return flow === "expense" && !["cardPayment", "bankTransfer", "income", "credit", "refund", "msi"].includes(kind ?? "other");
}
