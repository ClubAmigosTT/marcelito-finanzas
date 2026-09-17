import assert from "node:assert/strict";
import { test } from "node:test";
import {
  compareMarketingVersions,
  highestMarketingVersion,
  parseMarketingVersion,
} from "../scripts/validate-testflight-marketing-version.mjs";

test("compara versiones de marketing como números, no como texto", () => {
  assert.equal(compareMarketingVersions("1.0.106", "1.0.6"), 1);
  assert.equal(compareMarketingVersions("1.0.7", "1.0.106"), -1);
  assert.equal(compareMarketingVersions("1.0", "1.0.0"), 0);
});

test("ignora versiones de App Store Connect mal formadas", () => {
  assert.deepEqual(parseMarketingVersion("1.0.107"), [1, 0, 107]);
  assert.equal(parseMarketingVersion("1.0.107-bootstrap"), null);
  assert.equal(highestMarketingVersion(["1.0.6", "1.0.106", "legacy"]), "1.0.106");
});
