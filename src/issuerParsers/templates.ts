import santanderCheckingTemplateJson from "../../schemas/statement-templates/santander-checking-v1.json" with { type: "json" };
import type { DocumentLayout, DocumentLayoutLine, DocumentLayoutWord, NormalizedBox, TemplateMatch } from "./types.ts";
import { fold } from "./shared.ts";

type TemplateColumnKey = "FECHA" | "FOLIO" | "DESCRIPCION" | "DEPOSITO" | "RETIRO" | "SALDO";

type TemplateColumn = {
  key: TemplateColumnKey;
  aliases: string[];
  referenceBounds: NormalizedBox;
  headerAnchorX: number;
  role: "date" | "description" | "deposit" | "withdrawal" | "balance" | "excluded";
};

export type StatementTemplate = {
  schemaVersion: 1;
  id: string;
  version: string;
  displayName: string;
  issuer: string;
  statementKind: "bank" | "card";
  coordinateSpace: "normalized-bottom-left";
  headerSignature: {
    institutionalAny: string[];
    tableTitleAll: string[];
    /**
     * A decorative section title is OCR-fragile. A template may explicitly
     * allow its absence only when the institutional header, complete
     * calibrated table schema and at least two dated table rows are present.
     */
    allowMissingTitleWhenColumnsVerified: boolean;
    minimumAlignmentScore: number;
  };
  movementRegions: Array<{ id: string; pageRole: string; referenceBounds: NormalizedBox }>;
  columns: TemplateColumn[];
  excludedTextPatterns?: string[];
  validation: {
    requireDate: boolean;
    requireDescription: boolean;
    requireSingleMovementColumn: boolean;
    requireRunningBalanceEvidence: boolean;
    reconciliationTolerance: number;
  };
};

export const santanderCheckingTemplateV1 = santanderCheckingTemplateJson as StatementTemplate;

const requiredTemplateColumns: Array<[TemplateColumnKey, TemplateColumn["role"]]> = [
  ["FECHA", "date"],
  ["DESCRIPCION", "description"],
  ["DEPOSITO", "deposit"],
  ["RETIRO", "withdrawal"],
  ["SALDO", "balance"],
];

/**
 * JSON Schema covers the serializable shape. This small runtime check covers
 * cross-field invariants JSON Schema cannot express (for example x + width).
 * A malformed future template must fail closed rather than silently become a
 * generic Santander reader.
 */
export function statementTemplateValidationError(template: StatementTemplate): string | undefined {
  const normalizedBounds = (bounds: NormalizedBox | undefined, label: string) => {
    if (!bounds || ![bounds.x, bounds.y, bounds.width, bounds.height].every(Number.isFinite)) return `${label}: non-finite-bounds`;
    if (bounds.x < 0 || bounds.y < 0 || bounds.width < 0 || bounds.height < 0
      || bounds.x + bounds.width > 1 || bounds.y + bounds.height > 1) return `${label}: bounds-out-of-range`;
    return undefined;
  };
  if (template.schemaVersion !== 1 || !template.id || !template.version
    || template.coordinateSpace !== "normalized-bottom-left") return "template: identity-or-coordinate-space-invalid";
  if (!template.headerSignature.institutionalAny.length || !template.headerSignature.tableTitleAll.length
    || typeof template.headerSignature.allowMissingTitleWhenColumnsVerified !== "boolean"
    || !Number.isFinite(template.headerSignature.minimumAlignmentScore)
    || template.headerSignature.minimumAlignmentScore < 0 || template.headerSignature.minimumAlignmentScore > 1) {
    return "template: header-signature-invalid";
  }
  if (!template.movementRegions.length) return "template: movement-regions-missing";
  for (const region of template.movementRegions) {
    const error = normalizedBounds(region.referenceBounds, `region:${region.id}`);
    if (error) return error;
  }
  const keys = new Set<TemplateColumnKey>();
  for (const column of template.columns) {
    if (keys.has(column.key) || !column.aliases.length || !Number.isFinite(column.headerAnchorX)
      || column.headerAnchorX < 0 || column.headerAnchorX > 1) return `column:${column.key}: identity-invalid`;
    keys.add(column.key);
    const error = normalizedBounds(column.referenceBounds, `column:${column.key}`);
    if (error) return error;
    if (column.headerAnchorX < column.referenceBounds.x
      || column.headerAnchorX > column.referenceBounds.x + column.referenceBounds.width) {
      return `column:${column.key}: anchor-outside-bounds`;
    }
  }
  if (!requiredTemplateColumns.every(([key, role]) => template.columns.some((column) => column.key === key && column.role === role))) {
    return "template: required-columns-missing";
  }
  if (template.validation.reconciliationTolerance < 0 || template.validation.reconciliationTolerance > 0.05
    || !template.validation.requireDate || !template.validation.requireDescription
    || !template.validation.requireSingleMovementColumn || !template.validation.requireRunningBalanceEvidence) {
    return "template: validation-contract-invalid";
  }
  return undefined;
}

function clamp(value: number) {
  return Math.max(0, Math.min(1, value));
}

function tokenText(value: string) {
  return fold(value).replace(/[^a-z0-9]+/g, "");
}

function wordWidth(word: DocumentLayoutWord) {
  return word.width && word.width > 0 ? word.width : 0;
}

/**
 * Locates a label even when OCR emitted the entire table header as one token.
 * In that fallback, geometry is interpolated *only inside the recognised
 * header token*; arbitrary transaction text is never used for calibration.
 */
function hasColumnAlias(word: DocumentLayoutWord, column: TemplateColumn) {
  const text = tokenText(word.text);
  return column.aliases.some((alias) => text.includes(tokenText(alias)));
}

function labelAnchor(
  line: DocumentLayoutLine,
  column: TemplateColumn,
  columns: TemplateColumn[],
  referenceBounds: NormalizedBox,
): number | undefined {
  // Template anchors are the leading edge of the printed header label. This
  // is stable across Vision and Tesseract even when either engine estimates a
  // different word width for accents or split glyphs.
  const standalone = line.words.find((word) => hasColumnAlias(word, column) && wordWidth(word) < 0.45);
  if (standalone) return clamp(standalone.x);

  // OCR may instead return the entire header as one line. Character spacing
  // does not match table spacing, so project this template anchor across the
  // detected header extent. This is an affine range alignment, never a guess
  // based on body text or an absolute pixel coordinate.
  const combined = line.words.find((word) => wordWidth(word) >= 0.45
    && columns.filter((candidate) => hasColumnAlias(word, candidate)).length >= 4);
  if (!combined) return undefined;
  const relative = (column.headerAnchorX - referenceBounds.x) / referenceBounds.width;
  return clamp(combined.x + wordWidth(combined) * relative);
}

function tableTitlePresent(value: string, template: StatementTemplate) {
  const normalized = fold(value);
  return template.headerSignature.tableTitleAll.every((token) => normalized.includes(token));
}

function lineBounds(line: DocumentLayoutLine, fallback: NormalizedBox): NormalizedBox {
  const xs = line.words.map((word) => word.x);
  const rights = line.words.map((word) => word.x + wordWidth(word));
  const ys = line.words.flatMap((word) => word.y === undefined ? [] : [word.y]);
  const tops = line.words.flatMap((word) => word.y === undefined ? [] : [word.y + (word.height ?? 0)]);
  if (!xs.length) return fallback;
  const x = Math.min(...xs);
  const right = Math.max(...rights, x);
  const y = ys.length ? Math.min(...ys) : fallback.y;
  const top = tops.length ? Math.max(...tops, y) : y + fallback.height;
  return { x: clamp(x), y: clamp(y), width: clamp(right) - clamp(x), height: Math.max(0, clamp(top) - clamp(y)) };
}

type HeaderCandidate = {
  page: number;
  line: DocumentLayoutLine;
  anchors: Record<TemplateColumnKey, number>;
  score: number;
};

function candidateHeader(layout: DocumentLayout | undefined, template: StatementTemplate): HeaderCandidate | undefined {
  if (!layout) return undefined;
  const reference = template.movementRegions[0]?.referenceBounds ?? { x: 0, y: 0, width: 1, height: 1 };
  const required = template.columns.filter((column) => column.key !== "FOLIO");
  const candidates: HeaderCandidate[] = [];
  for (const page of layout.pages) {
    for (let start = 0; start < page.lines.length; start += 1) {
      const window = page.lines.slice(start, start + 3);
      const firstY = window[0]?.words[0]?.y ?? 0;
      const nearby = window.filter((line) => Math.abs((line.words[0]?.y ?? firstY) - firstY) <= 0.075);
      if (!nearby.length) continue;
      const line: DocumentLayoutLine = { page: page.page, words: nearby.flatMap((item) => item.words) };
      const anchors = {} as Record<TemplateColumnKey, number>;
      for (const column of template.columns) {
        const anchor = labelAnchor(line, column, template.columns, reference);
        if (anchor !== undefined) anchors[column.key] = anchor;
      }
      if (!required.every((column) => anchors[column.key] !== undefined)) continue;
      const order = ["FECHA", "DESCRIPCION", "DEPOSITO", "RETIRO", "SALDO"] as const;
      if (!order.every((key, index) => index === 0 || anchors[key] > anchors[order[index - 1]])) continue;
      const date = anchors.FECHA;
      const balance = anchors.SALDO;
      const referenceDate = template.columns.find((column) => column.key === "FECHA")!.headerAnchorX;
      const referenceBalance = template.columns.find((column) => column.key === "SALDO")!.headerAnchorX;
      if (balance - date <= 0.2 || referenceBalance - referenceDate <= 0) continue;
      const geometry = ["DESCRIPCION", "DEPOSITO", "RETIRO"] as const;
      const averageRelativeError = geometry.reduce((sum, key) => {
        const expected = (template.columns.find((column) => column.key === key)!.headerAnchorX - referenceDate)
          / (referenceBalance - referenceDate);
        const actual = (anchors[key] - date) / (balance - date);
        return sum + Math.abs(actual - expected);
      }, 0) / geometry.length;
      const score = Math.max(0, 1 - averageRelativeError / 0.10);
      candidates.push({ page: page.page, line, anchors, score });
    }
  }
  return candidates.sort((left, right) => right.score - left.score)[0];
}

/**
 * This is deliberately a table-local signal, not a generic date search. It
 * proves that the recognised headers are followed by at least two candidate
 * movement rows in the FECHA region on the same page. It is only used when
 * the printed section title itself was not readable by OCR.
 */
function hasVerifiedTableRows(layout: DocumentLayout | undefined, header: HeaderCandidate): boolean {
  const page = layout?.pages.find((candidate) => candidate.page === header.page);
  if (!page) return false;
  const headerBounds = lineBounds(header.line, { x: 0, y: 0, width: 1, height: 1 });
  const dateBoundary = header.anchors.DESCRIPCION;
  const dateToken = /(?:^|\s)[0-9OBI]{1,3}\s*[./-]\s*(?:\d{1,2}|[a-záéíóúñ]{3})(?:\s*[./-]\s*\d{2,4})?(?:\s|$)/i;
  const rows = page.lines.filter((line) => {
    const bounds = lineBounds(line, { x: 0, y: 0, width: 1, height: 1 });
    if (bounds.y >= headerBounds.y - 0.006) return false;
    return line.words.some((word) => word.x < dateBoundary && dateToken.test(word.text));
  });
  return rows.length >= 2;
}

function calibratedColumns(template: StatementTemplate, header: HeaderCandidate): TemplateMatch["columns"] {
  const anchor = header.anchors;
  const column = (key: TemplateColumnKey) => template.columns.find((item) => item.key === key)!;
  const reference = template.movementRegions[0]?.referenceBounds ?? { x: 0.045, y: 0.04, width: 0.91, height: 0.76 };
  const scale = (anchor.SALDO - anchor.FECHA) / (column("SALDO").headerAnchorX - column("FECHA").headerAnchorX);
  const transform = (referenceX: number) => anchor.FECHA + (referenceX - column("FECHA").headerAnchorX) * scale;
  const tableLeft = transform(reference.x);
  const tableRight = transform(reference.x + reference.width);
  const dateStart = tableLeft;
  const descriptionStart = transform(column("DESCRIPCION").referenceBounds.x);
  const depositStart = transform(column("DEPOSITO").referenceBounds.x);
  const withdrawalStart = transform(column("RETIRO").referenceBounds.x);
  const balanceStart = transform(column("SALDO").referenceBounds.x);
  const safe = (value: number) => clamp(value);
  return {
    FECHA: { x: safe(dateStart), y: reference.y, width: Math.max(0, safe(descriptionStart) - safe(dateStart)), height: reference.height },
    DESCRIPCION: { x: safe(descriptionStart), y: reference.y, width: Math.max(0, safe(depositStart) - safe(descriptionStart)), height: reference.height },
    DEPOSITO: { x: safe(depositStart), y: reference.y, width: Math.max(0, safe(withdrawalStart) - safe(depositStart)), height: reference.height },
    RETIRO: { x: safe(withdrawalStart), y: reference.y, width: Math.max(0, safe(balanceStart) - safe(withdrawalStart)), height: reference.height },
    SALDO: { x: safe(balanceStart), y: reference.y, width: Math.max(0, safe(tableRight) - safe(balanceStart)), height: reference.height },
  };
}

/**
 * Matches the reusable template before any row is parsed. The template is a
 * reference range, not a fixed crop: labels detected in this document define
 * the actual column boundaries. A failed match intentionally has no generic
 * Santander fallback.
 */
export function matchSantanderCheckingTemplate(layout: DocumentLayout | undefined, text: string): TemplateMatch {
  const template = santanderCheckingTemplateV1;
  const templateError = statementTemplateValidationError(template);
  const normalized = fold(text);
  const institutional = template.headerSignature.institutionalAny.some((token) => normalized.includes(fold(token)));
  const title = tableTitlePresent(text, template);
  const header = candidateHeader(layout, template);
  const base = {
    templateId: template.id,
    templateVersion: template.version,
    calibratedPages: header ? [header.page] : [],
    inheritedPages: layout?.pages.map((page) => page.page).filter((page) => page !== header?.page) ?? [],
  };
  if (templateError) {
    return { ...base, status: "review", alignmentScore: 0, reason: `santander.template-resource-invalid:${templateError}` };
  }
  if (!institutional) {
    return { ...base, status: "review", alignmentScore: 0, reason: "santander.template-institutional-header-missing" };
  }
  if (!header) {
    return { ...base, status: "review", alignmentScore: 0.5, reason: "santander.template-required-columns-missing" };
  }
  const verifiedRows = hasVerifiedTableRows(layout, header);
  if (!title && !template.headerSignature.allowMissingTitleWhenColumnsVerified) {
    return { ...base, status: "review", alignmentScore: 0.5, reason: "santander.template-movement-title-missing" };
  }
  if (!title && !verifiedRows) {
    return { ...base, status: "review", alignmentScore: 0.5, reason: "santander.template-title-and-row-signal-missing" };
  }
  // With a title, geometry earns 60% and issuer/title 20% each. Without the
  // decorative title, the same v1 template can still match, but geometry
  // earns 80% and must be correspondingly tighter; the verified rows above
  // prove this is a real movement table, not an unrelated header.
  const alignmentScore = Number(((title ? 0.4 + header.score * 0.6 : 0.2 + header.score * 0.8)).toFixed(4));
  if (alignmentScore < template.headerSignature.minimumAlignmentScore) {
    return { ...base, status: "review", alignmentScore, reason: "santander.template-geometry-misaligned" };
  }
  return {
    ...base,
    status: "matched",
    alignmentScore,
    reason: title
      ? "santander.template-matched-and-calibrated"
      : "santander.template-matched-with-verified-header-and-rows",
    columns: calibratedColumns(template, header),
  };
}

export function isWithinColumn(word: DocumentLayoutWord, bounds: NormalizedBox | undefined) {
  if (!bounds) return false;
  const center = word.x + wordWidth(word) / 2;
  return center >= bounds.x && center < bounds.x + bounds.width;
}

export function templateLineBounds(line: DocumentLayoutLine) {
  return lineBounds(line, { x: 0, y: 0, width: 1, height: 1 });
}
