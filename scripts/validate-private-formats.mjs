import { readFile, readdir, writeFile, realpath } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { auditNativeRows, cents } from './audit-native-rows.mjs';

const fields = {
  previousBalance: 'extractedPreviousBalance', cashBalance: 'extractedCashBalance',
  extractedDepositTotal: 'extractedDeposits', extractedWithdrawalTotal: 'extractedWithdrawals',
  extractedChargeTotal: 'extractedCharges', extractedPaymentTotal: 'extractedPayments',
  creditLimit: 'extractedCreditLimit', creditAvailable: 'extractedCreditAvailable',
  debtBalance: 'extractedDebtBalance', paymentForNoInterest: 'extractedPaymentForNoInterest',
  minimumPlusMsi: 'extractedMinimumPlusMsi', msiPending: 'extractedMsiPending',
};
const decimal = value => (typeof value === 'number' && Number.isFinite(value)) || typeof value === 'string'
  ? cents(String(value)) : null;
const flag = value => value === true || value === 'true';
const count = value => /^(0|[1-9]\d*)$/.test(String(value)) ? Number(value) : NaN;

export function nativeEvidence(log) {
  function one(marker) {
    const matches = [...log.matchAll(new RegExp(`^${marker} (.+)$`, 'gm'))];
    // Do not cherry-pick a passing run from an ambiguous concatenated log.
    if (matches.length !== 1) throw Error('native-log-marker-count');
    return JSON.parse(matches[0][1]);
  }
  return { summary: one('NATIVE_CORPUS_SUMMARY'), files: one('NATIVE_CORPUS_REPORT') };
}

/** Read-only evaluator. A successful preflight is never native certification.
 * Logs/exports are evidence supplied by the native runner, not cryptographic attestation.
 */
export function validateBank({ manifest, inventory, native, rows, reference, readerVersion }) {
  const errors = [];
  const files = Array.isArray(manifest?.files) ? manifest.files : [];
  if (manifest?.schemaVersion !== 1 || manifest?.tolerance !== 0 || !files.length) errors.push('manifest-schema');
  if (!readerVersion || manifest?.readerVersion !== readerVersion) errors.push('manifest-reader-version');
  const hashes = new Set(), names = new Set();
  const documents = files.map((file, index) => {
    const issues = [], checks = [];
    const fail = code => issues.push(code);
    if (!/^[a-f0-9]{64}$/.test(file.sourceFingerprint ?? '') || hashes.has(file.sourceFingerprint)) fail('manifest-fingerprint');
    hashes.add(file.sourceFingerprint);
    if (typeof file.file !== 'string' || path.basename(file.file) !== file.file || names.has(file.file)) fail('manifest-filename');
    names.add(file.file);
    const original = inventory.filter(x => x.file === file.file);
    if (original.length !== 1 || original[0]?.sourceFingerprint !== file.sourceFingerprint || original[0]?.pdf !== true) fail('original-integrity');
    if (!['Santander', 'Amex'].includes(file.source) || file.status !== 'valid'
        || !Number.isInteger(file.rows) || file.rows < 1 || !file.summary) fail('manifest-expectation');
    const required = file.source === 'Santander'
      ? ['previousBalance', 'cashBalance', 'extractedDepositTotal', 'extractedWithdrawalTotal']
      : ['extractedChargeTotal', 'extractedPaymentTotal', 'creditLimit', 'creditAvailable', 'debtBalance', 'paymentForNoInterest', 'minimumPlusMsi', 'msiPending'];
    for (const field of required) if (decimal(file.summary?.[field]) === null) fail(`missing-control:${field}`);
    if (file.source === 'Santander' && required.every(f => decimal(file.summary?.[f]) !== null)) {
      const s = file.summary;
      if (decimal(s.previousBalance) + decimal(s.extractedDepositTotal) - decimal(s.extractedWithdrawalTotal) !== decimal(s.cashBalance)) fail('reference-balance-equation');
    }
    if (!native) fail('native-evidence-missing');
    else {
      const matches = Array.isArray(native.files) ? native.files.filter(x => x.sourceFingerprint === file.sourceFingerprint) : [];
      const got = matches[0];
      if (matches.length !== 1) fail('native-document-missing-or-duplicate');
      else {
        for (const field of ['source', 'accountKey', 'kind']) if (got[field] !== file[field]) fail(`native-${field}`);
        if (got.status !== 'valid' || got.sourceStatus !== 'verified' || flag(got.requiresReview) || ![false, 'false'].includes(got.requiresReview)) fail('native-not-accepted');
        if (got.mode !== (file.source === 'Amex' ? 'pdf-text' : 'vision-ocr')) fail('native-wrong-pipeline');
        if (file.source === 'Santander' && !flag(got.ocrColumnsCalibrated)) fail('native-columns');
        if (count(got.rows) !== file.rows) fail('native-row-count');
        for (const field of required) {
          const expected = decimal(file.summary[field]), actual = decimal(got[fields[field]]);
          const passed = expected !== null && actual !== null && expected === actual;
          checks.push({ field, expectedCents: expected?.toString() ?? null, actualCents: actual?.toString() ?? null, passed });
          if (!passed) fail(`control:${field}`);
        }
      }
    }
    const ref = reference?.files?.filter(x => x.sourceFingerprint === file.sourceFingerprint) ?? [];
    if (reference?.referenceMethod !== 'visual-independent' || ref.length !== 1 || !ref[0]?.rows?.length) fail('independent-reference-missing');
    if (!rows) fail('row-export-missing');
    else {
      const found = rows.files?.filter(x => x.sourceFingerprint === file.sourceFingerprint) ?? [];
      if (found.length !== 1) fail('row-document-missing-or-duplicate');
      else {
        const got = found[0];
        if (got.status !== 'valid' || got.mode !== (file.source === 'Amex' ? 'pdf-text' : 'vision-ocr')) fail('row-document-not-valid');
        if (!Array.isArray(got.rows) || got.rows.length !== file.rows || got.rows.some(x => x.accepted !== true || typeof x.rawText !== 'string' || !x.rawText.trim())) fail('row-diagnostics-rejected-or-missing');
        if (ref.length === 1) {
          const audit = auditNativeRows({ ...reference, files: ref }, { ...rows, files: found }, readerVersion);
          if (!audit.passed) issues.push(...audit.errors.map(x => `row-audit:${x}`));
        }
        if (file.source === 'Santander') {
          const values = Array.isArray(got.candidateRows) ? got.candidateRows.map(x => cents(x.signedAmount)) : [];
          if (!values.length || values.some(x => x === null)) fail('bank-row-amounts');
          else {
            const deposits = values.filter(x => x > 0n).reduce((s, x) => s + x, 0n);
            const withdrawals = -values.filter(x => x < 0n).reduce((s, x) => s + x, 0n);
            if (deposits !== decimal(file.summary.extractedDepositTotal) || withdrawals !== decimal(file.summary.extractedWithdrawalTotal)) fail('bank-row-totals');
          }
        }
      }
    }
    return { document: index + 1, source: file.source, integrityPassed: !issues.some(x => x.startsWith('original-')), passed: issues.length === 0, checks, errors: issues };
  });
  if (inventory.length !== files.length || inventory.some(x => !names.has(x.file))) errors.push('unexpected-originals');
  if (native) {
    const s = native.summary;
    if (s?.readerVersion !== readerVersion) errors.push('native-reader-version');
    for (const field of ['files', 'accepted', 'expectedValid', 'goldenAutoAccepted']) if (count(s?.[field]) !== files.length) errors.push(`native-summary:${field}`);
    for (const field of ['blocked', 'expectedPending', 'goldenFalseAccepted', 'unresolvedOCR']) if (count(s?.[field]) !== 0) errors.push(`native-summary:${field}`);
    if (Number(s?.automaticAcceptancePrecision) !== 1) errors.push('native-summary:precision');
    if (!Array.isArray(native.files) || native.files.length !== files.length || native.files.some(x => !hashes.has(x.sourceFingerprint))) errors.push('unexpected-native-documents');
  }
  if (rows && (rows.schemaVersion !== 1 || rows.readerVersion !== readerVersion || !Array.isArray(rows.files) || rows.files.length !== files.length || rows.files.some(x => !hashes.has(x.sourceFingerprint)))) errors.push('row-export-scope-or-version');
  return { passed: !errors.length && documents.every(x => x.passed), errors, documents };
}

export async function validatePrivateFormats(root, referencePath, readerVersion) {
  const optional = async file => { try { return await readFile(file, 'utf8'); } catch (e) { if (e.code === 'ENOENT') return null; throw e; } };
  const refText = await optional(referencePath), reference = refText ? JSON.parse(refText) : null;
  const banks = {};
  for (const [bank, expectedFiles] of [['santander', 4], ['amex', 3]]) {
    const dir = path.join(root, bank), manifest = JSON.parse(await readFile(path.join(dir, 'controls.expected.json'), 'utf8'));
    const pdfDir = await realpath(path.join(dir, 'pdfs'));
    const inventory = [];
    for (const file of (await readdir(pdfDir)).filter(x => x.toLowerCase().endsWith('.pdf'))) {
      const resolved = await realpath(path.join(pdfDir, file));
      if (path.dirname(resolved) !== pdfDir) throw Error('PDF outside private corpus');
      const data = await readFile(resolved);
      inventory.push({ file, sourceFingerprint: createHash('sha256').update(data).digest('hex'), pdf: data.subarray(0, 5).toString() === '%PDF-' });
    }
    const log = await optional(path.join(dir, 'native.log'));
    const rowText = await optional(path.join(dir, 'row-diagnostics.json'));
    banks[bank] = validateBank({ manifest, inventory, native: log ? nativeEvidence(log) : null, rows: rowText ? JSON.parse(rowText) : null, reference, readerVersion });
    if (manifest.files.length !== expectedFiles || manifest.files.some(x => x.source !== (bank === 'amex' ? 'Amex' : 'Santander'))) {
      banks[bank].errors.push('closed-dataset-scope'); banks[bank].passed = false;
    }
  }
  return { schemaVersion: 1, generatedAt: new Date().toISOString(), readerVersion,
    scope: 'four-santander-three-amex', scopeValidated: Object.values(banks).every(x => x.passed),
    fullAppCertified: false, banks };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const root = path.resolve(process.argv[2] ?? 'private-corpus/amex-santander');
  const reference = path.resolve(process.argv[3] ?? 'private-corpus/independent-rows.json');
  try {
    const source = await readFile(new URL('../apps/ios/Cauce/Models.swift', import.meta.url), 'utf8');
    const version = source.match(/static let readerVersion = "([^"]+)"/)?.[1];
    const result = await validatePrivateFormats(root, reference, version);
    await writeFile(path.join(root, 'latest-validation.json'), JSON.stringify(result, null, 2) + '\n', { flag: 'w' });
    console.log(JSON.stringify({ scopeValidated: result.scopeValidated, fullAppCertified: false,
      banks: Object.fromEntries(Object.entries(result.banks).map(([bank, r]) => [bank, { files: r.documents.length,
        integrityPassed: r.documents.filter(x => x.integrityPassed).length, passed: r.documents.filter(x => x.passed).length,
        blockers: [...new Set([...r.errors, ...r.documents.flatMap(x => x.errors)])] }])) }, null, 2));
    process.exitCode = result.scopeValidated ? 0 : 1;
  } catch {
    console.error('Validation failed: missing, malformed or unsafe private inputs. No financial contents logged.');
    process.exitCode = 2;
  }
}
