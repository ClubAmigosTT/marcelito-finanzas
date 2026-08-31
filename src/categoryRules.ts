/**
 * A stable, privacy-preserving key for a merchant correction.
 *
 * Statements often add references, branch numbers or punctuation to the
 * same merchant. Removing those volatile tokens lets a correction carry over
 * to the next monthly PDF without uploading the description anywhere.
 */
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
