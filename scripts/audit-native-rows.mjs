import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

// No floating point or rounding: malformed amounts must not become matches.
export function cents(value) {
  if (typeof value !== 'string' || !/^-?\d+(?:\.\d{1,2})?$/.test(value)) return null;
  const negative = value.startsWith('-');
  const [whole, fraction = ''] = value.replace(/^-/, '').split('.');
  const result = BigInt(whole) * 100n + BigInt(fraction.padEnd(2, '0'));
  return negative ? -result : result;
}

/** Compares a private iPhone export with a separately reviewed reference.
 * Outputs ordinals and field names only, never private descriptions or amounts.
 * A passing row audit is NOT corpus certification or proof of classification.
 */
export function auditNativeRows(reference, report, readerVersion) {
  const normalize = value => value.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase().replace(/\s+/g, ' ').trim();
  const errors = [];
  if (reference?.schemaVersion !== 1 || reference?.referenceMethod !== 'visual-independent') errors.push('reference-schema');
  if (report?.schemaVersion !== 1) errors.push('report-schema');
  if (!readerVersion || report?.readerVersion !== readerVersion) errors.push('reader-version');
  const expected = Array.isArray(reference?.files) ? reference.files : [];
  const actual = Array.isArray(report?.files) ? report.files : [];
  if (!expected.length) errors.push('empty-reference');
  const seen = new Set();
  for (const [index, file] of expected.entries()) {
    const label = `document-${index + 1}`;
    const hash = file.sourceFingerprint;
    if (typeof hash !== 'string' || !/^[a-f0-9]{64}$/.test(hash) || seen.has(hash)) {
      errors.push(`${label}:reference-fingerprint`); continue;
    }
    seen.add(hash);
    const matches = actual.filter(item => item.sourceFingerprint === hash);
    if (matches.length !== 1) { errors.push(`${label}:missing-or-duplicate-export`); continue; }
    const received = matches[0];
    for (const field of ['source', 'accountKey', 'period']) {
      if (typeof file[field] !== 'string' || !file[field] || received[field] !== file[field]) errors.push(`${label}:${field}`);
    }
    const rows = Array.isArray(file.rows) ? file.rows : [];
    const candidates = Array.isArray(received.candidateRows) ? received.candidateRows : [];
    if (!rows.length || rows.length !== candidates.length) errors.push(`${label}:row-count`);
    for (const [ordinal, row] of rows.entries()) {
      const got = candidates[ordinal];
      const prefix = `${label}:row-${ordinal + 1}`;
      if (!got) { errors.push(`${prefix}:missing`); continue; }
      if (!/^\d{4}-\d{2}-\d{2}$/.test(row.date) || got.date !== row.date) errors.push(`${prefix}:date`);
      if (!Number.isInteger(row.page) || row.page < 1 || got.page !== row.page) errors.push(`${prefix}:page`);
      if (cents(row.signedAmount) === null || cents(got.signedAmount) !== cents(row.signedAmount)) errors.push(`${prefix}:signedAmount`);
      if (typeof row.titleContains !== 'string' || !row.titleContains || typeof got.title !== 'string'
          || !normalize(got.title).includes(normalize(row.titleContains))) errors.push(`${prefix}:description`);
    }
    if (file.controls) {
      const amounts = rows.map(row => cents(row.signedAmount));
      if (amounts.some(amount => amount === null)) { errors.push(`${label}:reference-controls`); continue; }
      const deposits = amounts.filter(amount => amount > 0n);
      const withdrawals = amounts.filter(amount => amount < 0n);
      const sum = values => values.reduce((total, value) => total + value, 0n);
      const controls = file.controls;
      const opening = cents(controls.openingBalance), closing = cents(controls.closingBalance);
      if (sum(deposits) !== cents(controls.deposits) || -sum(withdrawals) !== cents(controls.withdrawals)
          || deposits.length !== controls.depositCount || withdrawals.length !== controls.withdrawalCount
          || opening === null || closing === null || opening + sum(amounts) !== closing) errors.push(`${label}:reference-controls`);
    }
  }
  // Unreferenced PDFs cannot silently disappear from the result.
  const unreferenced = actual.filter(file => !seen.has(file.sourceFingerprint)).length;
  if (unreferenced) errors.push('unreferenced-documents');
  return { passed: errors.length === 0, referencedFiles: expected.length, exportedFiles: actual.length,
    unreferencedFiles: unreferenced, errors, corpusCertified: false };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [referencePath, exportPath, version] = process.argv.slice(2);
  if (!referencePath || !exportPath || !version) {
    console.error('Usage: node scripts/audit-native-rows.mjs <private-reference.json> <iphone-export.json> <reader-version>');
    process.exitCode = 2;
  } else {
    try {
      const result = auditNativeRows(JSON.parse(await readFile(referencePath, 'utf8')),
        JSON.parse(await readFile(exportPath, 'utf8')), version);
      console.log(JSON.stringify(result, null, 2));
      if (!result.passed) process.exitCode = 1;
    } catch {
      console.error('Could not read or parse audit inputs. No private contents logged.');
      process.exitCode = 2;
    }
  }
}
