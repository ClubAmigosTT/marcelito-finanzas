import assert from "node:assert/strict";
import { access, readFile, stat } from "node:fs/promises";
import test from "node:test";
import { URL } from "node:url";

const sectionsPath = new URL("../apps/ios/Cauce/Sections.swift", import.meta.url);
const modelsPath = new URL("../apps/ios/Cauce/Models.swift", import.meta.url);
const rootPath = new URL("../apps/ios/Cauce/RootTabView.swift", import.meta.url);
const assetsRoot = new URL("../apps/ios/Cauce/Assets.xcassets/", import.meta.url);

test("Cuentas permite deslizar entre las cuatro tarjetas y filtra sus estados", async () => {
  const source = await readFile(sectionsPath, "utf8");
  const accountsStart = source.indexOf("struct AccountsView");
  const accountsEnd = source.indexOf("private struct AccountTrendPoint", accountsStart);
  const accounts = source.slice(accountsStart, accountsEnd);

  assert.ok(accountsStart >= 0 && accountsEnd > accountsStart);
  assert.match(source, /case amex[\s\S]*case bbva[\s\S]*case santander[\s\S]*case rappi/);
  assert.match(accounts, /TabView\(selection: carouselSelection\)/);
  assert.match(accounts, /\.tabViewStyle\(\.page\(indexDisplayMode: \.always\)\)/);
  assert.match(accounts, /store\.statements\(for: account\.source, kind: account\.kind, accountKey: account\.accountKey\)/);
  assert.match(accounts, /Text\("Estados subidos"\)/);
  assert.match(accounts, /Text\(conciseStatementPeriod\(statement\)\)/);
  assert.doesNotMatch(accounts, /Text\(statement\.fileName\)/);
});

test("los estados de una cuenta se ordenan por la fecha real del corte", async () => {
  const source = await readFile(modelsPath, "utf8");
  const helperStart = source.indexOf("func statements(for source:");
  const helperEnd = source.indexOf("var totalNewTransactions", helperStart);
  const helper = source.slice(helperStart, helperEnd);

  assert.ok(helperStart >= 0 && helperEnd > helperStart);
  assert.match(helper, /statement\.source == source/);
  assert.match(helper, /statementKind\(statement\) == kind/);
  assert.match(helper, /statement\.accountKey == accountKey/);
  assert.match(helper, /statementEndDate\(for: left\.id\)/);
  assert.match(helper, /leftDate > rightDate/);
});

test("las imágenes entregadas están incluidas y el nombre del PDF queda sólo como fallback", async () => {
  for (const asset of ["CardAmex", "CardBBVA", "CardSantander", "CardRappi"]) {
    const image = new URL(`${asset}.imageset/${asset}.jpg`, assetsRoot);
    const contents = new URL(`${asset}.imageset/Contents.json`, assetsRoot);
    await access(image);
    await access(contents);
    assert.ok((await stat(image)).size > 10_000, `${asset} debe contener la imagen real`);
  }

  const source = await readFile(rootPath, "utf8");
  assert.match(source, /if item\.period == nil \{[\s\S]*Text\(item\.fileName\)/);
});
