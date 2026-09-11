import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { URL } from 'node:url';
import test from 'node:test';

const models = readFileSync(new URL('../apps/ios/Cauce/Models.swift', import.meta.url), 'utf8');
const screenshots = readFileSync(new URL('../apps/ios/Cauce/BankScreenshotImport.swift', import.meta.url), 'utf8');
const calendar = readFileSync(new URL('../apps/ios/Cauce/SpendingCalendar.swift', import.meta.url), 'utf8');
const nativeTests = readFileSync(new URL('../apps/ios/Tests/FinancialLogicAuditTests.swift', import.meta.url), 'utf8');

test('net spending uses one signed contribution without a zero floor', () => {
  assert.match(models, /kind == \.refund \? -amount : abs\(amount\)/);
  assert.match(models, /netExpenseMovements.reduce\(0\) \{ \$0 \+ \$1.expenseContribution \}/);
  assert.doesNotMatch(models, /max\(Decimal\(0\), cardRealSpend/);
  assert.match(calendar, /store.netExpenseMovements/);
  assert.match(nativeTests, /testRefundClosesCategoryCalendarMonthlyAndFlow/);
});

test('matching requires identity evidence and preserves ambiguous observations', () => {
  assert.match(models, /ownEvidence && evidence.score >= 90/);
  assert.match(models, /financialAccountKey\(outflow\)/);
  assert.match(screenshots, /possibleDuplicateOf = duplicate.row.id/);
  assert.match(screenshots, /descriptionScore >= 0.65/);
  assert.match(screenshots, /candidates\[0\].1 - candidates\[1\].1 >= 8/);
  assert.match(nativeTests, /testOwnScreenshotTransferWithAccountAndOwnerEvidence/);
});

test('balances preserve signed cash and do not invent obligations', () => {
  assert.match(models, /let cash = statement.summary\?\.cashBalance\s/);
  assert.doesNotMatch(models, /cashBalance.map\(absolute\)/);
  assert.match(models, /latestCompleteMetrics\(\.card\).map\(\\.paymentForNoInterest\)/);
  assert.doesNotMatch(models, /previousBalance.map \{ max\(Decimal\(0\), \$0 - realPayments/);
  assert.match(nativeTests, /testAllCardsIncludedAndMissingValueNotZero/);
});

test('calendar averages require coverage and equal elapsed-day windows', () => {
  assert.match(calendar, /points.prefix\(comparableDayCount\).reduce/);
  assert.match(calendar, /historyDays.filter\(\\.isCovered\)/);
  assert.doesNotMatch(calendar, /\+ 1 - 7/);
  assert.match(calendar, /Sin cobertura/);
  assert.match(nativeTests, /testMissingCalendarDaysAreNotZeroSamples/);
});

test('manual classification survives normalization and excludes AI rewrites', () => {
  assert.match(models, /restoreManualReviews\(\)/);
  assert.match(models, /guard !movements\[index\].manuallyReviewed else \{ continue \}/);
  assert.match(models, /encode\(manuallyReviewed/);
  assert.match(nativeTests, /testManualReviewSurvivesNormalization/);
});
