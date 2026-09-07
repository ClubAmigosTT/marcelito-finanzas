import type { DeterministicParseInput, DeterministicParseResult } from "./types.ts";
import { parseSantander } from "./santander.ts";
import { parseBBVA } from "./bbva.ts";
import { parseAmex } from "./amex.ts";

export function parseDeterministicStatement(input: DeterministicParseInput): DeterministicParseResult {
  if (input.source === "Santander") return parseSantander(input);
  if (input.source === "BBVA") return parseBBVA(input);
  if (input.source === "Amex") return parseAmex(input);
  throw new Error(`No existe un parser determinista para ${input.source}`);
}

export { reconcileExactly } from "./shared.ts";
export type { DeterministicParseInput, DeterministicParseResult, DocumentLayout, DocumentLayoutLine, DocumentLayoutPage, DocumentLayoutWord } from "./types.ts";
