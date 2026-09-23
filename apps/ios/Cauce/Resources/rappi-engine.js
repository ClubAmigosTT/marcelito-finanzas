var MarcelitoRappiEngine = (function(exports) {
  "use strict";
  function fold$1(value) {
    return value.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().replace(/\s+/g, " ").trim();
  }
  function cents(value) {
    if (value === void 0) return void 0;
    if (typeof value === "number") return Number.isFinite(value) ? Math.round(value * 100) : void 0;
    const clean = value.replace(/[$\s]/g, "").replace(/^\(/, "").replace(/\)$/, "").replace(/,/g, "");
    if (!/^-?\d+(?:\.\d{2})?$/.test(clean)) return void 0;
    const parsed = Number(clean);
    return Number.isFinite(parsed) ? Math.round(parsed * 100) : void 0;
  }
  function money(value) {
    const parsed = cents(value);
    return parsed === void 0 ? void 0 : parsed / 100;
  }
  function layoutLines(layout) {
    return layout?.pages.flatMap((page) => page.lines.map((line) => ({ ...line, page: page.page }))) ?? [];
  }
  function lineText(line) {
    return line.words.map((word) => word.text).join(" ").replace(/\s+/g, " ").trim();
  }
  const months = {
    ene: 1,
    enero: 1,
    feb: 2,
    febrero: 2,
    mar: 3,
    marzo: 3,
    abr: 4,
    abril: 4,
    may: 5,
    mayo: 5,
    jun: 6,
    junio: 6,
    jul: 7,
    julio: 7,
    ago: 8,
    agosto: 8,
    sep: 9,
    septiembre: 9,
    setiembre: 9,
    oct: 10,
    octubre: 10,
    nov: 11,
    noviembre: 11,
    dic: 12,
    diciembre: 12
  };
  function statementYear(text, fileName) {
    const years = Array.from(`${text}
${fileName}`.matchAll(/\b(20\d{2})\b/g)).map((match) => Number(match[1]));
    return years.find((year) => year >= 2e3 && year <= 2100) ?? (/* @__PURE__ */ new Date()).getFullYear();
  }
  function parseIssuerDate(token, text, fileName) {
    const normalized = fold$1(token).replace(/ag0/g, "ago").replace(/^o(?=\d)/, "0");
    const iso = normalized.match(/^(20\d{2})[-/.](\d{1,2})[-/.](\d{1,2})$/);
    if (iso) {
      const year2 = Number(iso[1]);
      const month2 = Number(iso[2]);
      const day2 = Number(iso[3]);
      const date2 = new Date(Date.UTC(year2, month2 - 1, day2));
      if (date2.getUTCFullYear() !== year2 || date2.getUTCMonth() !== month2 - 1 || date2.getUTCDate() !== day2) return void 0;
      return `${year2}-${String(month2).padStart(2, "0")}-${String(day2).padStart(2, "0")}`;
    }
    const numeric = normalized.match(/^(\d{1,2})[-/.](\d{1,2})[-/.](20\d{2})$/);
    if (numeric) return `${numeric[3]}-${numeric[2].padStart(2, "0")}-${numeric[1].padStart(2, "0")}`;
    const named = normalized.match(/^(\d{1,2})(?:\s+de\s+|[-/])([a-z]+)(?:\s+de\s+|[-/])?(20\d{2})?$/) ?? normalized.match(/^(\d{1,2})\s+(?:de\s+)?([a-z]+)(?:\s+(?:de\s+)?(20\d{2}))?$/);
    if (!named) return void 0;
    const month = months[named[2]] ?? months[named[2].slice(0, 3)];
    const day = Number(named[1]);
    if (!month || day < 1 || day > 31) return void 0;
    const year = Number(named[3] ?? statementYear(text, fileName));
    const date = new Date(Date.UTC(year, month - 1, day));
    if (date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) return void 0;
    return `${year}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
  }
  function makeTransaction(options) {
    const amount = options.amountCents / 100;
    const flow = options.kind === "cardPayment" ? "debt" : amount > 0 ? "income" : "expense";
    const key = options.fileName.normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/[^a-z0-9]+/gi, "-").replace(/^-|-$/g, "").slice(0, 32).toLowerCase() || "estado";
    return {
      id: `${options.parser}-${key}-${options.index + 1}`,
      date: options.date,
      description: options.description.replace(/\s+/g, " ").trim().slice(0, 120),
      account: options.account,
      category: options.category ?? (options.merchantReviewReason ? "Por revisar" : options.kind === "cardPayment" || options.kind === "bankTransfer" ? "Transferencia" : "Sin categoría"),
      amount,
      flow,
      kind: options.kind,
      foreignCurrency: options.foreignCurrency,
      confidence: options.confidence,
      rawDescription: options.rawDescription ?? options.description,
      normalizedMerchant: options.normalizedMerchant,
      displayMerchant: options.displayMerchant,
      merchantConfidence: options.merchantConfidence,
      merchantReviewReason: options.merchantReviewReason,
      extractionEvidence: {
        method: options.mode === "ocr" ? "ocr" : "pdf-text",
        page: options.page,
        confidence: options.confidence,
        sourceText: options.sourceText.slice(0, 240),
        bounds: options.bounds,
        sameVisualRow: options.sameVisualRow === null ? options.bounds ? true : void 0 : options.sameVisualRow ?? true,
        reviewReason: options.merchantReviewReason,
        selectionReason: options.selectionReason
      }
    };
  }
  function totalCents(rows, predicate) {
    return rows.filter(predicate).reduce((total, row) => total + Math.abs(cents(row.amount) ?? 0), 0);
  }
  function reconcileExactly(kind, summary, rows) {
    const invalid = (reason, extra2 = {}) => ({
      status: "invalid",
      tolerance: 0,
      extractedMovementCount: rows.length,
      reason,
      ...extra2
    });
    if (!summary) return invalid("Faltan los controles oficiales del estado");
    const purchaseKinds = /* @__PURE__ */ new Set(["purchase", "interest", "fee"]);
    const chargeCents = totalCents(rows, (row) => row.amount < 0 && purchaseKinds.has(row.kind ?? "other"));
    const msiCents = totalCents(rows, (row) => row.amount < 0 && row.kind === "msi");
    const paymentCents = totalCents(rows, (row) => row.kind === "cardPayment");
    const creditCents = totalCents(rows, (row) => row.amount > 0 && (row.kind === "credit" || row.kind === "refund"));
    const domesticChargeCents = totalCents(rows, (row) => row.amount < 0 && purchaseKinds.has(row.kind ?? "other") && !row.foreignCurrency);
    const foreignChargeCents = totalCents(rows, (row) => row.amount < 0 && purchaseKinds.has(row.kind ?? "other") && Boolean(row.foreignCurrency));
    const domesticCreditCents = totalCents(rows, (row) => row.amount > 0 && (row.kind === "credit" || row.kind === "refund") && !row.foreignCurrency);
    const foreignCreditCents = totalCents(rows, (row) => row.amount > 0 && (row.kind === "credit" || row.kind === "refund") && Boolean(row.foreignCurrency));
    const expectedCharges = cents(summary.newTransactions);
    const extra = {
      extractedChargeTotal: chargeCents / 100,
      extractedDomesticChargeTotal: domesticChargeCents / 100,
      extractedForeignChargeTotal: foreignChargeCents / 100,
      extractedCreditTotal: creditCents / 100,
      extractedPaymentTotal: paymentCents / 100,
      extractedMsiTotal: msiCents / 100,
      creditIdentityDifference: summary.creditLimit !== void 0 && summary.creditAvailable !== void 0 && summary.debtBalance !== void 0 ? ((cents(summary.creditLimit) ?? 0) - (cents(summary.creditAvailable) ?? 0) - (cents(summary.debtBalance) ?? 0)) / 100 : void 0
    };
    if (expectedCharges === void 0) return invalid("Falta el total oficial de Nuevas transacciones", extra);
    const errors = [];
    if (chargeCents !== expectedCharges) errors.push(`nuevas transacciones ${(chargeCents - expectedCharges) / 100}`);
    const expectedPaymentsCredits = cents(summary.paymentsCredits);
    if (expectedPaymentsCredits !== void 0 && paymentCents + creditCents !== expectedPaymentsCredits) errors.push(`pagos y créditos ${(paymentCents + creditCents - expectedPaymentsCredits) / 100}`);
    const expectedNewCharges = cents(summary.newCharges);
    if (expectedNewCharges !== void 0 && chargeCents + msiCents !== expectedNewCharges) errors.push(`nuevos cargos ${(chargeCents + msiCents - expectedNewCharges) / 100}`);
    const expectedDomestic = cents(summary.domesticTransactionTotal);
    if (expectedDomestic !== void 0) {
      const actualDomestic = domesticChargeCents - domesticCreditCents;
      const matchesDomestic = summary.domesticTransactionTotalIsCredit ? actualDomestic === -expectedDomestic : Math.abs(actualDomestic) === expectedDomestic;
      if (!matchesDomestic) errors.push(`sección nacional ${(Math.abs(actualDomestic) - expectedDomestic) / 100}`);
    }
    const expectedForeign = cents(summary.foreignTransactionTotal);
    if (expectedForeign !== void 0 && foreignChargeCents - foreignCreditCents !== expectedForeign) errors.push(`moneda extranjera ${(foreignChargeCents - foreignCreditCents - expectedForeign) / 100}`);
    const limit = cents(summary.creditLimit);
    const available = cents(summary.creditAvailable);
    const debt = cents(summary.debtBalance);
    if (limit !== void 0 && available !== void 0 && debt !== void 0 && limit - available !== debt) errors.push(`deuda utilizada ${(limit - available - debt) / 100}`);
    const statementBalance = cents(summary.statementBalance);
    const msiPending = cents(summary.msiPending);
    if (statementBalance !== void 0 && msiPending !== void 0 && debt !== void 0 && statementBalance + msiPending !== debt) errors.push(`saldo más MSI ${(statementBalance + msiPending - debt) / 100}`);
    const paymentForNoInterest = cents(summary.paymentForNoInterest);
    if (paymentForNoInterest !== void 0 && statementBalance !== void 0 && paymentForNoInterest !== statementBalance) errors.push("pago para no generar intereses no coincide con saldo actual");
    return errors.length ? invalid(`No concilia al centavo: ${errors.join(", ")}`, extra) : { status: "valid", tolerance: 0, extractedMovementCount: rows.length, ...extra };
  }
  function normalizedDescription(description) {
    return description.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().replace(/[^a-z0-9]+/g, " ").replace(/\s+/g, " ").trim();
  }
  function containsAny(text, markers) {
    const padded = ` ${text} `;
    return markers.some((marker) => {
      const normalizedMarker = normalizedDescription(marker);
      if (!normalizedMarker) return false;
      return padded.includes(` ${normalizedMarker} `) || normalizedMarker.length >= 6 && text.includes(normalizedMarker);
    });
  }
  function merchantLabel(description) {
    const label = description.replace(/\s+/g, " ").replace(/\b(?:aut\.?|ref\.?|folio|no\.?|num\.?)[\s:#-]*[a-z0-9-]+/gi, "").trim();
    return (label || "Sin descripción").slice(0, 80);
  }
  const projectMarkers = ["club amigos", "clubamigos", "proyecto", "proveedor club", "material club"];
  const financeMarkers = ["comision", "interes", "iva com", "cargo bancario", "cajero", "anualidad", "seguro financiero", "financiera", "finanzas"];
  const softwareMarkers = ["canva", "cursor", "google one", "google storage", "youtube premium", "apple music", "adobe", "microsoft 365", "microsoft office", "suscripcion", "suscripción", "saas", "software", "icloud", "dropbox", "apple com bill", "apple com mx"];
  const travelMarkers = ["airbnb", "booking", "expedia", "hotel", "hospedaje", "aeromexico", "aerobus", "volaris", "vivaaerobus", "american airlines", "united airlines", "delta air", "iberia", "vuelo", "flight", "holafly", "esim", "roaming", "equipaje", "airport", "aeropuerto", "renta de auto", "car rental", "nueva york", "new york", "medellin", "medellín", "atlanta"];
  const entertainmentMarkers = ["cinemex", "cinemas wtc", "cinepolis", "cine", "teatro", "museo", "museum", "moma", "guggenheim", "summit one", "concierto", "festival", "boleto", "ticket", "show", "smoke jazz", "jazz", "nekoma", "club nocturno", "experiencia", "ocio"];
  const sportMarkers = ["club deportivo", "club deportivo kanoa", "asdeporte", "pickleball", "padel", "pádel", "cancha", "renta de cancha", "gimnasio", "gym", "deporte", "competencia"];
  const healthMarkers = ["farmacia", "farmacias", "hospital", "clinica", "clínica", "doctor", "consultorio", "dentista", "dental", "odont", "laboratorio", "salud", "medic", "medico", "medical", "tratamiento"];
  const restaurantMarkers = ["restaurant", "rest ", "taquer", "taco", "sushi", "cafe", "coffee", "starbucks", "burger", "pizza", "pub", "bar ", "comida", "food", "delivery", "rappi", "didi food", "flauta", "ramen", "italian", "crepes", "cerv", "mariscos", "grill", "cocina", "parrilla", "chipotle", "doordash", "ubereats", "uber eats", "casa de tono", "espeto", "japiramen", "orinoco", "waffles"];
  const convenienceMarkers = ["oxxo", "7 eleven", "seven eleven", "7-eleven", "extra", "circle k", "minisuper", "mini super", "tienda de conveniencia", "convenience store", "snack", "abarrotes pequeno"];
  const groceryMarkers = ["walmart", "superama", "soriana", "costco", "chedraui", "la comer", "city market", "sam s", "sams ", "supermercado", "grocery", "whole foods", "wholefds", "despensa", "abarrotes", "mercado grande"];
  const transportMarkers = ["uber", "didi", "cabify", "taxi", "metrobus", "metro ", "metrotap", "nyct", "nj transit", "njtransit", "nyc ferry", "subway", "mta ", "train ", "estacionamiento", "parking", "parco ", "gasolina", "pemex", "shell", "bp ", "gulf", "mobil", "caseta", "autopista", "toll", "ecobici", "transporte", "movilidad"];
  const personalShoppingMarkers = ["apple", "shein", "amazon", "sanborns", "miniso", "old navy", "mercadolibre", "mercado libre", "mercadopago", "lumen", "steren", "boutique", "tienda", "shop", "store", "ropa", "zapateria", "departamental", "electronic", "electronico", "accesorio", "compras"];
  const recurringMarkers = [...softwareMarkers, "renta", "telcel", "at&t", "movistar", "izzi", "totalplay", "cfe", "luz ", "agua ", "internet", "seguro", "membresia", "membresía"];
  function deterministicExpenseClassification(description, flow = "expense", kind = "purchase") {
    if (flow !== "expense" || ["cardPayment", "bankTransfer", "income", "credit", "refund", "msi"].includes(kind ?? "other")) return void 0;
    const text = normalizedDescription(description);
    const merchant = merchantLabel(description);
    const project = containsAny(text, projectMarkers);
    let category = "Otros / Por revisar";
    let reason = "El descriptor no permite identificar la naturaleza del gasto con suficiente seguridad.";
    let confidence = 0.35;
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
    const tags = [];
    tags.push(project ? "proyecto" : "personal");
    const travel = category === "Viajes" || containsAny(text, travelMarkers);
    if (travel) tags.push("viaje");
    const fixed = containsAny(text, recurringMarkers);
    tags.push(fixed ? "fijo" : "variable");
    const extraordinary = travel || category === "Entretenimiento" || containsAny(text, ["evento", "concierto", "festival", "emergencia", "reparacion", "reparación"]);
    tags.push(extraordinary ? "extraordinario" : "ordinario");
    return { category, merchant, tags, confidence, reason };
  }
  const rappiCategoryRules = [
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
    { category: "Restaurantes y bares", pattern: /\b(?:cafe|cafeteria|cafesitio|shake\s+shack|serena\s+horneando|los\s+gueros|tacos?|tortas?|crepas?|mcdonalds?|chili\s*s|casa\s*de\s*tono|maison\s+kayser|cevicheria|la\s+pancita|volovaneria|el\s+globo|fastfood|restaurant|rest\b|rest[a-z]{3,}|mezcaleria|barbacoa)\b|(?:cafeteria|cafesitio|mcdonalds?|sazonjarocho|tortasin|barbacoawtc|gajrest|resttonal|casadetono)/ }
  ];
  function fold(value) {
    return value.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
  }
  function compact(value) {
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
    { pattern: /pago\s+por\s+spei/i, merchant: "pago por spei", display: "Pago por SPEI" }
  ];
  const technicalToken = /\b(?:rfc|ref(?:erencia)?|folio|aut(?:orizaci[oó]n)?|operaci[oó]n|c[oó]digo|codigo|no\.?\s*de?)\s*[:#./_-]*\s*[a-z0-9-]+/gi;
  const processorPrefix = /^(?:merpago|mercadopago|payu|paypal|conekta|clip(?:\s+mx)?|bpk|d\s+local|pgb|com\s+rap)\s*[*:/-]?\s*/i;
  function removeTechnicalFragments(value) {
    return compact(value.replace(technicalToken, " ").replace(/(?:^|\s)[/#*;|]+(?=\s|$)/g, " ").replace(/\s*[/;|]\s*$/g, "").replace(/^\s*[/;|]+\s*/g, ""));
  }
  function displayCase(value) {
    if (!/[a-záéíóúüñ]/.test(value) && /[A-ZÁÉÍÓÚÜÑ]/.test(value)) {
      return value.toLocaleLowerCase("es-MX").replace(/(^|[\s-])([a-záéíóúüñ])/g, (_, prefix, letter) => `${prefix}${letter.toLocaleUpperCase("es-MX")}`);
    }
    return value;
  }
  function stableKey(value) {
    return fold(value).replace(technicalToken, " ").replace(/[^a-z0-9]+/g, " ").replace(/\s+/g, " ").trim();
  }
  function normalizeRappiMerchant(value) {
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
    const likelyOpaqueProcessorDescriptor = processorDerived && (/[0-9]/.test(merchantCore) || merchantCore.length < 4);
    const confidence = alias ? 0.96 : !letters || tooLong ? 0.48 : likelyOpaqueProcessorDescriptor || noisy ? 0.7 : merchantCore.length >= 3 ? 0.88 : 0.58;
    const reviewReason = likelyOpaqueProcessorDescriptor ? "El texto conserva un identificador de procesador; confirma el comercio con la descripción original." : confidence < 0.75 ? !letters ? "La descripción no conserva un nombre de comercio legible." : "El comercio conserva evidencia, pero la normalización no es suficientemente confiable." : void 0;
    return { rawDescription, normalizedMerchant, displayMerchant, confidence, reviewReason };
  }
  function rappiCategoryFor(value, normalizedMerchant, flow, kind) {
    if (flow !== "expense" || ["cardPayment", "bankTransfer", "income", "credit", "refund", "msi"].includes(kind ?? "")) {
      return void 0;
    }
    const text = fold(`${value} ${normalizedMerchant}`).replace(/[^a-z0-9]+/g, " ").replace(/\s+/g, " ").trim();
    return rappiCategoryRules.find((rule) => rule.pattern.test(text))?.category;
  }
  const sectionTitle = "Cargos, abonos y compras regulares (no a meses)";
  const pageMarker = /^__pdf_page_(\d+)__$/;
  const rowDateToken = String.raw`(?:\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-/.](?:\d{1,2}|[a-z]{3,12})[-/.]\d{2,4}|\d{1,2}\s+(?:de\s+)?[a-z]{3,12}\s+(?:de\s+)?\d{2,4})`;
  const rowStart = new RegExp(`^(${rowDateToken})\\s+(${rowDateToken})(?:\\s+(.*))?$`, "i");
  const rowPairStart = new RegExp(`(?<![A-Za-z0-9.,])(?=${rowDateToken}\\s+${rowDateToken}\\s+)`, "i");
  const signedMoney = /(?<![A-Za-z0-9.,])([+-])\s*\$?\s*((?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2})(?![A-Za-z0-9.,])/g;
  function isAdministrativeOrTruncatedDescription(value) {
    const compact2 = fold$1(value).replace(/[^a-z0-9]+/g, "");
    return compact2.startsWith("desglosedemovimientos") || compact2.startsWith("cargosabonosycomprasregulares") || compact2 === "por";
  }
  function amountAfter(text, label) {
    const match = text.match(new RegExp(`${label.source}[^$\\n]{0,100}\\$\\s*([\\d,]+\\.\\d{2})`, "i"));
    return money(match?.[1]);
  }
  function parseSummary(text) {
    const regularCharges = amountAfter(text, /cargos\s+regulares\s*\(no\s+a\s+meses\)/i);
    const msiCharges = amountAfter(text, /cargos\s+compras\s+a\s+meses\s*\(capital\)/i) ?? 0;
    const paymentsCredits = amountAfter(text, /pagos\s+y\s+abonos/i);
    const previousBalance = amountAfter(text, /adeudo\s+del\s+periodo\s+anterior/i);
    const paymentForNoInterest = amountAfter(text, /pago\s+para\s+no\s+generar\s+intereses/i);
    const statementBalance = amountAfter(text, /saldo\s+deudor\s+total/i) ?? paymentForNoInterest;
    const creditLimit = amountAfter(text, /l[ií]mite\s+de\s+cr[eé]dito/i);
    const creditAvailable = amountAfter(text, /cr[eé]dito\s+disponible(?!\s+para)/i);
    const minimumPlusMsi = amountAfter(text, /pago\s+m[ií]nimo\s*\+\s*compras\s+y\s+cargos\s+diferidos/i);
    const minimumPayment = amountAfter(text, /pago\s+m[ií]nimo(?!\s*\+)/i);
    return {
      previousBalance,
      statementBalance,
      debtBalance: statementBalance,
      newTransactions: regularCharges,
      // Rappi's regular table is the auditable current-period section. MSI
      // capital is a future obligation and is intentionally not promoted to a
      // regular purchase row; reconcileExactly still validates the regular
      // total and the independent payment/credit controls.
      paymentsCredits,
      paymentForNoInterest,
      newCharges: msiCharges === 0 && regularCharges !== void 0 ? regularCharges : void 0,
      msiMonthlyLoad: msiCharges,
      msiPending: 0,
      creditLimit,
      creditAvailable,
      minimumPlusMsi,
      minimumPayment
    };
  }
  const rowBoundsMarker = /^__rappi_row_bounds__\s+(\d+)\s+(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)(?:\s+(\d+(?:\.\d+)?))?$/i;
  const rowMetaMarker = /^__rappi_row_meta__\s+(.+)$/i;
  function parseMoneyRows(input, sameVisualRow = null, rowConfidences = []) {
    const rows = [];
    const rejectedRows = [];
    let page = 1;
    let active = false;
    let pending;
    let rowConfidenceIndex = 0;
    let nextRowBounds;
    let nextRowConfidence;
    let nextSelectionReason;
    const finishRow = (rawValue, rowPage, rowForeignCurrency, rowConfidence, rowBounds, rowSelectionReason) => {
      const raw = rawValue.replace(/\s+/g, " ").trim();
      const match = raw.match(rowStart);
      if (!match) {
        rejectedRows.push(raw.slice(0, 240));
        return;
      }
      const date = parseIssuerDate(match[1], input.text, input.fileName);
      if (!date) {
        rejectedRows.push(raw.slice(0, 240));
        return;
      }
      const moneyMatches = [...raw.matchAll(signedMoney)];
      if (moneyMatches.length !== 1) {
        rejectedRows.push(raw.slice(0, 240));
        return;
      }
      const selected = moneyMatches[0];
      const amountCents = cents(selected[2]);
      if (amountCents === void 0 || amountCents <= 0) {
        rejectedRows.push(raw.slice(0, 240));
        return;
      }
      const signedValue = selected[1] === "-" ? -amountCents : amountCents;
      const descriptionEnd = selected.index ?? raw.length;
      const descriptionStart = match[0].length - (match[3]?.length ?? 0);
      const rawDescription = raw.slice(descriptionStart, descriptionEnd).replace(/\s+/g, " ").trim();
      const description = rawDescription.replace(/compra\s+en\s+el\s+extranjero/ig, "").replace(/tasa\s+de\s+conversi[oó]n\s+[^ ]+/ig, "").replace(/usd\s+\$?\s*[\d,.]+/ig, "").replace(/\s+/g, " ").trim();
      if (!description) {
        rejectedRows.push(raw.slice(0, 240));
        return;
      }
      if (isAdministrativeOrTruncatedDescription(description)) {
        rejectedRows.push(raw.slice(0, 240));
        return;
      }
      const normalizedDescription2 = fold$1(description);
      const merchant = normalizeRappiMerchant(description);
      const isPayment = /^pago\s+por\s+spei\b/.test(normalizedDescription2);
      const cashbackCredit = !isPayment && /bonificaci[oó]n|cashback|devoluci[oó]n|reembolso/.test(normalizedDescription2);
      const isRefund = !isPayment && (signedValue < 0 || cashbackCredit);
      let kind = "purchase";
      let ledgerAmountCents = -Math.abs(signedValue);
      if (isPayment) {
        kind = "cardPayment";
        ledgerAmountCents = -Math.abs(signedValue);
      } else if (isRefund) {
        kind = cashbackCredit ? "refund" : "credit";
        ledgerAmountCents = Math.abs(signedValue);
      }
      const rappiCategory = rappiCategoryFor(
        description,
        merchant.normalizedMerchant,
        isPayment ? "transfer" : ledgerAmountCents > 0 ? "income" : "expense",
        kind
      );
      const localCategory = isPayment ? "Transferencia" : merchant.reviewReason ? "Por revisar" : rappiCategory ?? deterministicExpenseClassification(description, kind === "cardPayment" ? "debt" : ledgerAmountCents > 0 ? "income" : "expense", kind)?.category ?? "Otros / Por revisar";
      rows.push(makeTransaction({
        parser: "rappicard-operations-v1",
        fileName: input.fileName,
        index: rows.length,
        date,
        description,
        account: "Rappi",
        amountCents: ledgerAmountCents,
        kind,
        page: rowPage,
        mode: input.mode,
        confidence: Number.isFinite(rowConfidence) ? Math.max(0, Math.min(1, rowConfidence)) : input.mode === "ocr" ? Math.max(0, Math.min(1, input.pageConfidences?.[rowPage - 1] ?? 0.9)) : 1,
        foreignCurrency: rowForeignCurrency,
        sourceText: raw,
        rawDescription,
        normalizedMerchant: merchant.normalizedMerchant,
        displayMerchant: merchant.displayMerchant,
        merchantConfidence: merchant.confidence,
        merchantReviewReason: merchant.reviewReason,
        category: localCategory,
        sameVisualRow,
        bounds: rowBounds,
        selectionReason: rowSelectionReason ?? (isPayment || cashbackCredit ? selected[1] === "+" ? "signo OCR corregido por etiqueta inequívoca de abono Rappi" : "importe firmado por etiqueta inequívoca de abono Rappi" : "importe firmado")
      }));
    };
    const finish = () => {
      if (!pending) return;
      const rowPage = pending.page;
      const rowForeignCurrency = pending.foreignCurrency;
      const rowBounds = pending.bounds;
      const rowPendingConfidence = pending.confidence;
      const rowSelectionReason = pending.selectionReason;
      const raw = pending.raw.replace(/\s+/g, " ").trim();
      pending = void 0;
      const rowSegments = raw.split(rowPairStart);
      for (const [index, segment] of rowSegments.entries()) {
        const confidence = rowConfidences.length ? rowConfidences[rowConfidenceIndex++] : rowPendingConfidence;
        finishRow(
          segment,
          rowPage,
          rowForeignCurrency,
          confidence,
          index === 0 ? rowBounds : void 0,
          index === 0 ? rowSelectionReason : void 0
        );
      }
    };
    for (const rawLine of input.text.split(/\r?\n/)) {
      const line = rawLine.replace(/\s+/g, " ").trim();
      if (!line) continue;
      const normalized = fold$1(line);
      const marker = normalized.match(pageMarker);
      if (marker) {
        finish();
        page = Number(marker[1]);
        nextRowBounds = void 0;
        nextRowConfidence = void 0;
        nextSelectionReason = void 0;
        continue;
      }
      if (normalized.includes(fold$1(sectionTitle))) {
        finish();
        active = true;
        continue;
      }
      if (/^total\s+de\s+(?:cargos|abonos)\b|^cargos\s+no\s+reconocidos|^atenci[oó]n\s+de\s+quejas|^notas\s+aclaratorias/.test(normalized)) {
        finish();
        active = false;
        continue;
      }
      if (!active) continue;
      const boundsMarker = line.match(rowBoundsMarker);
      if (boundsMarker) {
        finish();
        nextRowBounds = {
          x: Number(boundsMarker[2]),
          y: Number(boundsMarker[3]),
          width: Number(boundsMarker[4]),
          height: Number(boundsMarker[5])
        };
        nextRowConfidence = boundsMarker[6] === void 0 ? void 0 : Number(boundsMarker[6]);
        nextSelectionReason = void 0;
        continue;
      }
      const metaMarker = line.match(rowMetaMarker);
      if (metaMarker) {
        nextSelectionReason = metaMarker[1].trim();
        continue;
      }
      if (rowStart.test(line)) {
        finish();
        pending = {
          raw: line,
          page,
          foreignCurrency: false,
          bounds: nextRowBounds,
          confidence: nextRowConfidence,
          selectionReason: nextSelectionReason
        };
        nextRowBounds = void 0;
        nextRowConfidence = void 0;
        nextSelectionReason = void 0;
        continue;
      }
      if (!pending) continue;
      if (/compra\s+en\s+el\s+extranjero/.test(normalized)) pending.foreignCurrency = true;
      pending.raw += ` ${line}`;
    }
    finish();
    return { rows, rejectedRows };
  }
  function parseLayoutRows(input) {
    const lines = layoutLines(input.layout);
    if (!lines.length) return void 0;
    let active = false;
    let amountStart = 0.78;
    let descriptionStart = 0.28;
    const selectedRows = [];
    let pending;
    const normalizeDate = (token) => {
      const iso = token.match(/^(20\d{2})[-/.](\d{1,2})[-/.](\d{1,2})$/);
      return iso ? `${iso[1]}-${iso[2].padStart(2, "0")}-${iso[3].padStart(2, "0")}` : parseIssuerDate(token, input.text, input.fileName);
    };
    const finish = () => {
      if (!pending || !pending.amount || !pending.dates.length || !pending.description.trim()) {
        pending = void 0;
        return;
      }
      const firstDate = normalizeDate(pending.dates[0]);
      const secondDate = normalizeDate(pending.dates[1] ?? pending.dates[0]);
      if (!firstDate || !secondDate) {
        pending = void 0;
        return;
      }
      selectedRows.push({
        page: pending.page,
        text: `${firstDate} ${secondDate} ${pending.description.trim()} ${pending.amount}`,
        confidence: pending.confidence
      });
      pending = void 0;
    };
    const datePattern = new RegExp(`^(?:${rowDateToken})$`, "i");
    for (const line of lines) {
      const raw = lineText(line);
      const normalized = fold$1(raw);
      if (!active && normalized.includes(fold$1(sectionTitle))) {
        active = true;
        continue;
      }
      if (!active) continue;
      if (/^total\s+de\s+(?:cargos|abonos)\b|^cargos\s+no\s+reconocidos|^atenci[oó]n\s+de\s+quejas|^notas\s+aclaratorias/.test(normalized)) {
        finish();
        active = false;
        continue;
      }
      const headerAmount = line.words.find((word) => /^(?:monto|importe|cantidad)$/i.test(fold$1(word.text)));
      const headerDescription = line.words.find((word) => /^(?:descripci[oó]n|concepto)$/i.test(fold$1(word.text)));
      if (headerAmount) amountStart = Math.max(0.6, headerAmount.x - 0.06);
      if (headerDescription) descriptionStart = Math.max(0.16, headerDescription.x - 0.02);
      const dateWords = line.words.filter((word) => word.x < descriptionStart && datePattern.test(word.text.replace(/\s+/g, "").trim())).map((word) => word.text.replace(/\s+/g, "").trim());
      const amountCell = line.words.filter((word) => word.x >= amountStart).map((word) => word.text).join("").replace(/\s+/g, "");
      const amountMatch = amountCell.match(/[+-]\$?(?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2}/);
      const lineConfidence = line.words.length ? Math.max(0, Math.min(1, Math.min(...line.words.map((word) => word.confidence)))) : 0;
      if (dateWords.length) {
        finish();
        const description = line.words.filter((word) => word.x >= descriptionStart && word.x < amountStart).map((word) => word.text).join(" ");
        pending = { page: line.page, dates: dateWords.slice(0, 2), description, amount: amountMatch?.[0], confidence: lineConfidence };
        continue;
      }
      if (pending && !amountMatch) {
        const continuation = line.words.filter((word) => word.x >= descriptionStart && word.x < amountStart).map((word) => word.text).join(" ").trim();
        if (continuation) {
          pending.description = `${pending.description} ${continuation}`.trim();
          pending.confidence = Math.min(pending.confidence, lineConfidence);
        }
      }
    }
    finish();
    if (!selectedRows.length) return void 0;
    return parseMoneyRows(
      { ...input, text: `${sectionTitle}
${selectedRows.map((row) => `__PDF_PAGE_${row.page}__
${row.text}`).join("\n")}` },
      true,
      selectedRows.map((row) => row.confidence)
    );
  }
  function parseRappi(input) {
    const summary = parseSummary(input.text);
    const layoutParsed = input.mode === "ocr" ? parseLayoutRows(input) : void 0;
    const layoutReconciliation = layoutParsed ? reconcileExactly("card", summary, layoutParsed.rows) : void 0;
    const parsed = layoutParsed && layoutReconciliation?.status === "valid" ? layoutParsed : parseMoneyRows(input);
    const reconciliation = reconcileExactly("card", summary, parsed.rows);
    return {
      parserId: "rappicard-operations-v1",
      sourceSection: sectionTitle,
      transactions: parsed.rows,
      summary,
      reconciliation,
      rejectedRowCount: parsed.rejectedRows.length,
      rejectedRows: parsed.rejectedRows
    };
  }
  const RAPPI_SHARED_ENGINE_VERSION = "rappi-shared-engine-2026.09.23.1";
  const rappiSharedEngine = {
    version: RAPPI_SHARED_ENGINE_VERSION,
    parse(input) {
      return parseRappi({ ...input, source: "Rappi" });
    }
  };
  const runtime = globalThis;
  runtime.MarcelitoRappiEngine = rappiSharedEngine;
  exports.RAPPI_SHARED_ENGINE_VERSION = RAPPI_SHARED_ENGINE_VERSION;
  exports.rappiSharedEngine = rappiSharedEngine;
  Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
  return exports;
})({});

;globalThis.MarcelitoRappiEngine = globalThis.MarcelitoRappiEngine.rappiSharedEngine;
