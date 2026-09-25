import type { DeterministicParseInput, DeterministicParseResult } from "./issuerParsers/types.ts";
import { parseRappi } from "./issuerParsers/rappi.ts";

/**
 * Version of the pure Rappi interpretation contract embedded in iOS.
 *
 * PDFKit/Vision remain platform-specific extraction providers. Once either
 * provider has produced text (and, when available, layout words), this
 * contract is the single source of truth for row boundaries, signs, merchant
 * identity, categories and reconciliation.
 */
export const RAPPI_SHARED_ENGINE_VERSION = "rappi-shared-engine-2026.09.25.2";

export type RappiSharedEngineInput = Omit<DeterministicParseInput, "source"> & {
  source?: "Rappi";
};

export type RappiSharedEngineApi = {
  version: string;
  parse(input: RappiSharedEngineInput): DeterministicParseResult;
};

export const rappiSharedEngine: RappiSharedEngineApi = {
  version: RAPPI_SHARED_ENGINE_VERSION,
  parse(input) {
    return parseRappi({ ...input, source: "Rappi" });
  },
};

// The iOS bridge evaluates this file as a local JavaScript resource. Keep the
// global deliberately small and JSON-shaped so the bridge has no dependency
// on the web runtime, DOM APIs or a worker.
const runtime = globalThis as typeof globalThis & {
  MarcelitoRappiEngine?: RappiSharedEngineApi;
};
runtime.MarcelitoRappiEngine = rappiSharedEngine;
