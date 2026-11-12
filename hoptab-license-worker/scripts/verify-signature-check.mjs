#!/usr/bin/env node
/**
 * Standalone check for src/webhook-verify.ts.
 *
 * Builds a known-good Standard Webhooks signature with node:crypto (an
 * independent implementation from the verifier under test), asserts the
 * verifier accepts it, then mutates the body / secret / timestamp / signature
 * and asserts every one of those is rejected.
 *
 * Run with:  npm test      (from hoptab-license-worker/)
 */

import { createHmac, randomBytes, webcrypto } from "node:crypto";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { execFileSync } from "node:child_process";

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

// --- Build the TypeScript module so plain Node can import it ---------------

const outDir = mkdtempSync(join(tmpdir(), "hoptab-webhook-verify-"));
process.on("exit", () => rmSync(outDir, { recursive: true, force: true }));

execFileSync(
  process.execPath,
  [
    join(projectRoot, "node_modules", "typescript", "bin", "tsc"),
    "-p",
    join(projectRoot, "tsconfig.json"),
    "--noEmit",
    "false",
    "--outDir",
    outDir,
  ],
  { cwd: projectRoot, stdio: "inherit" }
);
writeFileSync(join(outDir, "package.json"), JSON.stringify({ type: "module" }));

const { verifyStandardWebhook, timingSafeEqual, webhookSecretKeyCandidates } = await import(
  pathToFileURL(join(outDir, "webhook-verify.js")).href
);

// --- Test helpers ----------------------------------------------------------

let passed = 0;
const failures = [];

function check(name, condition) {
  if (condition) {
    passed += 1;
    console.log(`  ok   ${name}`);
  } else {
    failures.push(name);
    console.log(`  FAIL ${name}`);
  }
}

/** Independent Standard Webhooks signer, per https://www.standardwebhooks.com */
function sign({ id, timestamp, body, secret }) {
  const material = secret.startsWith("whsec_") ? secret.slice("whsec_".length) : secret;
  const key = Buffer.from(material, "base64");
  const mac = createHmac("sha256", key).update(`${id}.${timestamp}.${body}`).digest("base64");
  return `v1,${mac}`;
}

/** Same, but for a Polar secret that is a plain (non-base64) string. */
function signRawSecret({ id, timestamp, body, secret }) {
  const material = secret.startsWith("whsec_") ? secret.slice("whsec_".length) : secret;
  const mac = createHmac("sha256", Buffer.from(material, "utf8"))
    .update(`${id}.${timestamp}.${body}`)
    .digest("base64");
  return `v1,${mac}`;
}

const SECRET = "whsec_" + randomBytes(24).toString("base64");
const OTHER_SECRET = "whsec_" + randomBytes(24).toString("base64");
const ID = "msg_2b1c8f1a9e3f4d0e";
const NOW = 1_757_000_000;
const TS = String(NOW);
const BODY = JSON.stringify({
  type: "order.created",
  data: {
    id: "c1a5f2e0-0000-4000-8000-000000000001",
    status: "paid",
    amount: 500,
    currency: "usd",
    product_id: "prod_hoptab_pro",
    product: { id: "prod_hoptab_pro", name: "HopTab Pro" },
    customer: { email: "buyer@example.com", name: "Buyer" },
  },
});

const base = { id: ID, timestamp: TS, body: BODY, secret: SECRET, nowSeconds: NOW };
const verify = (o) => verifyStandardWebhook({ ...base, ...o });

console.log("\nStandard Webhooks verification (src/webhook-verify.ts)\n");

// --- Accepts a genuine delivery -------------------------------------------

const goodSig = sign({ id: ID, timestamp: TS, body: BODY, secret: SECRET });
check("accepts a valid signature", (await verify({ signatureHeader: goodSig })).ok === true);

check(
  "accepts a valid signature at the edge of the tolerance window",
  (await verify({
    signatureHeader: sign({ id: ID, timestamp: String(NOW - 299), body: BODY, secret: SECRET }),
    timestamp: String(NOW - 299),
  })).ok === true
);

check(
  "accepts when one of several rotated keys matches (valid last)",
  (await verify({ signatureHeader: `v1,${randomBytes(32).toString("base64")} ${goodSig}` })).ok === true
);

check(
  "accepts when one of several rotated keys matches (valid first)",
  (await verify({ signatureHeader: `${goodSig} v1,${randomBytes(32).toString("base64")}` })).ok === true
);

check(
  "accepts a plain (non-base64) Polar secret via the raw-UTF-8 fallback",
  (await verify({
    secret: "whsec_not~base64~secret",
    signatureHeader: signRawSecret({
      id: ID,
      timestamp: TS,
      body: BODY,
      secret: "whsec_not~base64~secret",
    }),
  })).ok === true
);

check(
  "accepts a secret configured without the whsec_ prefix",
  (await verify({
    secret: SECRET.slice("whsec_".length),
    signatureHeader: goodSig,
  })).ok === true
);

// --- Rejects everything else ----------------------------------------------

const mutatedBody = BODY.replace('"amount":500', '"amount":0');
const r = async (o) => (await verify(o)).reason;

check(
  "rejects a mutated body (same signature)",
  (await verify({ signatureHeader: goodSig, body: mutatedBody })).ok === false
);
check("  ...with reason signature_mismatch", (await r({ signatureHeader: goodSig, body: mutatedBody })) === "signature_mismatch");

check(
  "rejects a body with one extra byte appended",
  (await verify({ signatureHeader: goodSig, body: BODY + " " })).ok === false
);

check(
  "rejects a signature made with a different secret",
  (await verify({
    signatureHeader: sign({ id: ID, timestamp: TS, body: BODY, secret: OTHER_SECRET }),
  })).ok === false
);

check(
  "rejects a tampered webhook-id",
  (await verify({ signatureHeader: goodSig, id: ID + "x" })).ok === false
);

check(
  "rejects a tampered webhook-timestamp",
  (await verify({ signatureHeader: goodSig, timestamp: String(NOW + 1) })).ok === false
);

check(
  "rejects a replay older than 5 minutes",
  (await r({
    signatureHeader: sign({ id: ID, timestamp: String(NOW - 301), body: BODY, secret: SECRET }),
    timestamp: String(NOW - 301),
  })) === "timestamp_out_of_tolerance"
);

check(
  "rejects a timestamp more than 5 minutes in the future",
  (await r({
    signatureHeader: sign({ id: ID, timestamp: String(NOW + 301), body: BODY, secret: SECRET }),
    timestamp: String(NOW + 301),
  })) === "timestamp_out_of_tolerance"
);

check("rejects a non-numeric timestamp", (await r({ signatureHeader: goodSig, timestamp: "not-a-number" })) === "bad_timestamp");

check("rejects a missing signature header", (await r({ signatureHeader: "" })) === "missing_headers");
check("rejects a missing webhook-id", (await r({ signatureHeader: goodSig, id: "" })) === "missing_headers");
check("rejects a null webhook-timestamp", (await r({ signatureHeader: goodSig, timestamp: null })) === "missing_headers");

check("FAILS CLOSED when the secret is unset", (await r({ signatureHeader: goodSig, secret: "" })) === "missing_secret");
check("FAILS CLOSED when the secret is undefined", (await r({ signatureHeader: goodSig, secret: undefined })) === "missing_secret");
check("FAILS CLOSED when the secret is only the whsec_ prefix", (await r({ signatureHeader: goodSig, secret: "whsec_" })) === "missing_secret");

check(
  "rejects an unknown signature version (v0)",
  (await r({ signatureHeader: goodSig.replace("v1,", "v0,") })) === "malformed_signature_header"
);
check(
  "rejects a signature header with no version prefix",
  (await r({ signatureHeader: goodSig.slice("v1,".length) })) === "malformed_signature_header"
);
check("rejects a garbage signature header", (await r({ signatureHeader: "!!!!" })) === "malformed_signature_header");

check(
  "rejects a truncated (prefix-matching) signature",
  (await verify({ signatureHeader: goodSig.slice(0, goodSig.length - 8) })).ok === false
);

// --- Constant-time compare -------------------------------------------------

check("timingSafeEqual: equal bytes match", timingSafeEqual(Uint8Array.from([1, 2, 3]), Uint8Array.from([1, 2, 3])));
check("timingSafeEqual: last byte differs", !timingSafeEqual(Uint8Array.from([1, 2, 3]), Uint8Array.from([1, 2, 4])));
check("timingSafeEqual: first byte differs", !timingSafeEqual(Uint8Array.from([9, 2, 3]), Uint8Array.from([1, 2, 3])));
check("timingSafeEqual: length differs", !timingSafeEqual(Uint8Array.from([1, 2, 3]), Uint8Array.from([1, 2, 3, 4])));
check(
  "timingSafeEqual source has no early return inside the compare loop",
  !/for \(let i = 0; i < len; i\+\+\) \{[^}]*return/s.test(timingSafeEqual.toString())
);

check("secret candidates: base64 secret yields both decoded and raw keys", webhookSecretKeyCandidates(SECRET).length === 2);
check("secret candidates: non-base64 secret yields the raw key only", webhookSecretKeyCandidates("whsec_not~base64~secret").length === 1);
check("secret candidates: empty secret yields nothing", webhookSecretKeyCandidates("whsec_").length === 0);

// ===========================================================================
// End-to-end: the real POST /polar/webhook route, against a mock KV namespace.
// This is what proves the P0 is closed — not just that the verifier works, but
// that the handler refuses to mint anything for an unsigned request.
// ===========================================================================

// tsc emits an extension-less relative import; Node ESM needs the .js.
{
  const indexPath = join(outDir, "index.js");
  writeFileSync(
    indexPath,
    readFileSync(indexPath, "utf8").replace('from "./webhook-verify"', 'from "./webhook-verify.js"')
  );
}
const worker = (await import(pathToFileURL(join(outDir, "index.js")).href)).default;

// A throwaway Ed25519 key so the handler can actually mint.
const keyPair = await webcrypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
const pkcs8 = new Uint8Array(await webcrypto.subtle.exportKey("pkcs8", keyPair.privateKey));
const ED25519_PRIVATE_KEY = Buffer.from(pkcs8.slice(16)).toString("base64"); // raw 32-byte seed

function makeKv() {
  const store = new Map();
  const counts = { puts: 0, deletes: 0 };
  return {
    store,
    counts,
    async get(key) {
      const v = store.get(key);
      return v === undefined ? null : v;
    },
    async put(key, value) {
      counts.puts += 1;
      store.set(key, value);
    },
    async delete(key) {
      counts.deletes += 1;
      store.delete(key);
    },
  };
}

const PRODUCT_ID = "3f2a1b00-0000-4000-8000-00000000abcd";
const CHECKOUT_ID = "c1a5f2e0-0000-4000-8000-000000000042";

function orderBody(overrides = {}) {
  return JSON.stringify({
    type: "order.created",
    data: {
      id: CHECKOUT_ID,
      status: "paid",
      amount: 500,
      currency: "usd",
      product_id: PRODUCT_ID,
      product: { id: PRODUCT_ID, name: "HopTab Pro" },
      customer: { email: "buyer@example.com", name: "Buyer" },
      ...overrides,
    },
  });
}

const capturedLogs = [];
function captureConsole(fn) {
  const original = { log: console.log, warn: console.warn, error: console.error };
  const sink = (...args) => capturedLogs.push(args.map(String).join(" "));
  console.log = sink;
  console.warn = sink;
  console.error = sink;
  return fn().finally(() => Object.assign(console, original));
}

async function postPolar({ secret, body, id, timestamp, signature, env: envOverrides = {}, kv }) {
  const headers = new Headers({ "content-type": "application/json" });
  if (id !== null) headers.set("webhook-id", id);
  if (timestamp !== null) headers.set("webhook-timestamp", timestamp);
  if (signature !== null) headers.set("webhook-signature", signature);

  const env = {
    GITHUB_WEBHOOK_SECRET: "unused",
    ED25519_PRIVATE_KEY,
    POLAR_WEBHOOK_SECRET: secret,
    POLAR_PRODUCT_ID: PRODUCT_ID,
    LICENSE_KV: kv,
    ...envOverrides,
  };

  const request = new Request("https://license.hoptab.app/polar/webhook", { method: "POST", headers, body });
  return captureConsole(() => worker.fetch(request, env));
}

function signedHeaders(body, secret, deliveryId, ts = Math.floor(Date.now() / 1000)) {
  return {
    id: deliveryId,
    timestamp: String(ts),
    signature: sign({ id: deliveryId, timestamp: String(ts), body, secret }),
  };
}

console.log("\nEnd-to-end: POST /polar/webhook\n");

// --- The P0 itself ---------------------------------------------------------

{
  const kv = makeKv();
  const res = await postPolar({
    secret: SECRET,
    body: orderBody(),
    id: "msg_forged",
    timestamp: String(Math.floor(Date.now() / 1000)),
    signature: null,
    kv,
  });
  check("P0: unsigned order.created is rejected with 401", res.status === 401);
  check("P0: unsigned order.created mints nothing", kv.counts.puts === 0 && kv.store.size === 0);
}

{
  const kv = makeKv();
  const res = await postPolar({
    secret: SECRET,
    body: orderBody(),
    id: "msg_forged",
    timestamp: String(Math.floor(Date.now() / 1000)),
    signature: `v1,${randomBytes(32).toString("base64")}`,
    kv,
  });
  check("P0: forged signature is rejected with 401", res.status === 401);
  check("P0: forged signature mints nothing", kv.counts.puts === 0);
}

{
  const kv = makeKv();
  const body = orderBody();
  const res = await postPolar({
    secret: SECRET,
    body,
    ...signedHeaders(body, OTHER_SECRET, "msg_wrongkey"),
    kv,
  });
  check("P0: signature from a different secret is rejected with 401", res.status === 401);
  check("P0: wrong-secret delivery mints nothing", kv.counts.puts === 0);
}

{
  const kv = makeKv();
  const body = orderBody();
  const signed = signedHeaders(body, SECRET, "msg_tampered");
  const res = await postPolar({ secret: SECRET, body: orderBody({ amount: 0 }), ...signed, kv });
  check("P0: body swapped after signing is rejected with 401", res.status === 401);
  check("P0: tampered-body delivery mints nothing", kv.counts.puts === 0);
}

// --- Fail closed -----------------------------------------------------------

for (const [label, secret] of [["unset", undefined], ["empty", ""], ["whitespace", "   "]]) {
  const kv = makeKv();
  const body = orderBody();
  const res = await postPolar({
    secret,
    body,
    ...signedHeaders(body, SECRET, `msg_nosecret_${label}`),
    kv,
  });
  check(`fails closed with 500 when POLAR_WEBHOOK_SECRET is ${label}`, res.status === 500);
  check(`mints nothing when POLAR_WEBHOOK_SECRET is ${label}`, kv.counts.puts === 0);
}

// --- Replay ----------------------------------------------------------------

{
  const kv = makeKv();
  const body = orderBody();
  const old = Math.floor(Date.now() / 1000) - 600;
  const res = await postPolar({ secret: SECRET, body, ...signedHeaders(body, SECRET, "msg_old", old), kv });
  check("replay of a 10-minute-old delivery is rejected with 401", res.status === 401);
  check("stale delivery mints nothing", kv.counts.puts === 0);
}

// --- The happy path still works -------------------------------------------

const happyKv = makeKv();
let issuedLicense = null;
{
  const body = orderBody();
  const res = await postPolar({ secret: SECRET, body, ...signedHeaders(body, SECRET, "msg_good_1"), kv: happyKv });
  check("verified order.created returns 200", res.status === 200);
  check("verified order.created responds { ok: true }", (await res.json()).ok === true);

  issuedLicense = happyKv.store.get(`checkout:${CHECKOUT_ID}`);
  check("verified order.created stores the license at checkout:<id>", typeof issuedLicense === "string");
  check("verified order.created stores the license at email:<email>", happyKv.store.get("email:buyer@example.com") === issuedLicense);
}

// --- The issued key is still the exact format LicenseValidator.swift parses -

{
  const parts = (issuedLicense ?? "").split(".");
  check("license key has 3 dot-separated parts", parts.length === 3);
  check("license key version suffix is still '1'", parts[2] === "1");

  const payloadBytes = Buffer.from(parts[0], "base64");
  const signatureBytes = Buffer.from(parts[1], "base64");
  check("license signature is 64 bytes (Ed25519)", signatureBytes.length === 64);

  const valid = await webcrypto.subtle.verify("Ed25519", keyPair.publicKey, signatureBytes, payloadBytes);
  check("license Ed25519 signature verifies against the public key", valid === true);

  const payload = JSON.parse(payloadBytes.toString("utf8"));
  check("license payload keeps app=hoptab", payload.app === "hoptab");
  check("license payload keeps tier=pro", payload.tier === "pro");
  check("license payload keeps sub/email/iat", payload.sub === "Buyer" && payload.email === "buyer@example.com" && typeof payload.iat === "number");
  check(
    "license payload has exactly the original 5 fields",
    JSON.stringify(Object.keys(payload)) === JSON.stringify(["sub", "email", "iat", "tier", "app"])
  );
}

// --- Idempotency -----------------------------------------------------------

{
  const putsAfterFirst = happyKv.counts.puts;
  const body = orderBody();
  const ts = String(Math.floor(Date.now() / 1000));
  const signature = sign({ id: "msg_good_1", timestamp: ts, body, secret: SECRET });
  const res = await postPolar({ secret: SECRET, body, id: "msg_good_1", timestamp: ts, signature, kv: happyKv });
  check("replayed valid delivery returns 200", res.status === 200);
  check("replayed valid delivery reports idempotent", (await res.json()).idempotent === true);
  check("replayed valid delivery writes nothing new", happyKv.counts.puts === putsAfterFirst);
  check("replayed valid delivery does not change the issued key", happyKv.store.get(`checkout:${CHECKOUT_ID}`) === issuedLicense);
}

// --- Product allowlist -----------------------------------------------------

{
  const kv = makeKv();
  const body = orderBody({ product_id: "some-other-product", product: { id: "some-other-product", name: "Sticker Pack" } });
  const res = await postPolar({ secret: SECRET, body, ...signedHeaders(body, SECRET, "msg_wrongproduct"), kv });
  check("verified order for a product outside POLAR_PRODUCT_ID is rejected with 400", res.status === 400);
  check("disallowed product mints nothing", kv.counts.puts === 0);
}

{
  const kv = makeKv();
  const body = orderBody({ product_id: "second-allowed-product", product: { id: "second-allowed-product", name: "HopTab Pro" } });
  const res = await postPolar({
    secret: SECRET,
    body,
    ...signedHeaders(body, SECRET, "msg_secondproduct"),
    env: { POLAR_PRODUCT_ID: `${PRODUCT_ID}, second-allowed-product` },
    kv,
  });
  check("comma-separated POLAR_PRODUCT_ID allowlist accepts every listed id", res.status === 200);
}

{
  const kv = makeKv();
  const body = orderBody({ amount: 100, product: { id: PRODUCT_ID, name: "Coffee" } });
  const res = await postPolar({ secret: SECRET, body, ...signedHeaders(body, SECRET, "msg_cheap"), kv });
  check("verified order under the Pro price with a non-Pro name mints nothing", kv.counts.puts === 0 && res.status === 200);
}

// --- Unexpected events -----------------------------------------------------

{
  const kv = makeKv();
  const body = JSON.stringify({ type: "subscription.canceled", data: { id: CHECKOUT_ID } });
  const res = await postPolar({ secret: SECRET, body, ...signedHeaders(body, SECRET, "msg_othertype"), kv });
  check("verified but unexpected event type mints nothing", kv.counts.puts === 0 && res.status === 200);
}

{
  const kv = makeKv();
  const body = JSON.stringify({ type: "checkout.updated", data: { id: CHECKOUT_ID, status: "open", product_id: PRODUCT_ID } });
  const res = await postPolar({ secret: SECRET, body, ...signedHeaders(body, SECRET, "msg_openstill"), kv });
  check("verified checkout.updated that is not succeeded mints nothing", kv.counts.puts === 0 && res.status === 200);
}

// --- Logging hygiene -------------------------------------------------------

check("no log line contains the webhook secret", !capturedLogs.some((l) => l.includes(SECRET) || l.includes(SECRET.slice(6))));
check("no log line contains the Ed25519 private key", !capturedLogs.some((l) => l.includes(ED25519_PRIVATE_KEY)));
check("no log line contains a full license key", !capturedLogs.some((l) => issuedLicense && l.includes(issuedLicense)));
check("no log line contains a raw signature header", !capturedLogs.some((l) => /v1,[A-Za-z0-9+/]{20}/.test(l)));

// ===========================================================================
// End-to-end: GET /license/<token>
// ===========================================================================

console.log("\nEnd-to-end: GET /license/<token>\n");

async function getLicense(token, kv, ip = "203.0.113.10") {
  const request = new Request(`https://license.hoptab.app/license/${token}`, {
    method: "GET",
    headers: { "cf-connecting-ip": ip },
  });
  return captureConsole(() =>
    worker.fetch(request, {
      GITHUB_WEBHOOK_SECRET: "unused",
      ED25519_PRIVATE_KEY,
      POLAR_WEBHOOK_SECRET: SECRET,
      LICENSE_KV: kv,
    })
  );
}

{
  const kv = makeKv();
  kv.store.set(`checkout:${CHECKOUT_ID}`, "PAYLOAD.SIG.1");
  kv.store.set("email:victim@example.com", "VICTIM.SIG.1");
  kv.store.set("user:royalbhati", "OWNER.SIG.1");

  const ok = await getLicense(CHECKOUT_ID, kv);
  const okBody = await ok.text();
  check("legitimate checkout id still returns the license page", ok.status === 200 && okBody.includes("PAYLOAD.SIG.1"));
  check("license page is marked no-store", (ok.headers.get("cache-control") ?? "").includes("no-store"));

  const byEmail = await getLicense("email:victim@example.com", kv, "203.0.113.11");
  check("KV key traversal via email: prefix is refused", byEmail.status === 400);
  check("KV key traversal via email: prefix leaks nothing", !(await byEmail.text()).includes("VICTIM.SIG.1"));

  const byUser = await getLicense("user:royalbhati", kv, "203.0.113.12");
  check("KV key traversal via user: prefix is refused", byUser.status === 400);
  check("KV key traversal via user: prefix leaks nothing", !(await byUser.text()).includes("OWNER.SIG.1"));

  const encoded = await getLicense(encodeURIComponent("user:royalbhati"), kv, "203.0.113.13");
  check("percent-encoded KV key traversal is refused", encoded.status === 400);

  const missing = await getLicense("11111111-2222-4333-8444-555555555555", kv, "203.0.113.14");
  check("unknown token shows the 'still generating' page, not an error", missing.status === 200);
}

{
  const kv = makeKv();
  kv.store.set("11111111-2222-4333-8444-555555555555", "ONETIME.SIG.1");
  const first = await getLicense("11111111-2222-4333-8444-555555555555", kv, "198.51.100.7");
  check("one-time GitHub token returns the license", (await first.text()).includes("ONETIME.SIG.1"));
  check("one-time GitHub token is burned after retrieval", kv.counts.deletes === 1 && kv.store.size === 0);
}

{
  const kv = makeKv();
  kv.store.set(`checkout:${CHECKOUT_ID}`, "PAYLOAD.SIG.1");
  const ip = "198.51.100.99";
  let limited = null;
  for (let i = 0; i < 70; i++) {
    const res = await getLicense(CHECKOUT_ID, kv, ip);
    if (res.status === 429) {
      limited = i;
      break;
    }
  }
  check("enumeration from one IP is rate limited", limited !== null);
  check("rate limit allows the 5s auto-refresh (>12 req/min) before tripping", limited === null || limited > 12);
  const other = await getLicense(CHECKOUT_ID, kv, "198.51.100.100");
  check("rate limit is per client IP, not global", other.status === 200);
}

// ===========================================================================
// End-to-end: POST /webhook (GitHub Sponsors)
// ===========================================================================

console.log("\nEnd-to-end: POST /webhook (GitHub Sponsors)\n");

async function postGitHub({ secret, envSecret, body, event = "sponsorship", kv }) {
  const headers = new Headers({ "content-type": "application/json", "x-github-event": event });
  if (secret !== null) {
    const mac = createHmac("sha256", secret).update(body).digest("hex");
    headers.set("x-hub-signature-256", `sha256=${mac}`);
  }
  const request = new Request("https://license.hoptab.app/webhook", { method: "POST", headers, body });
  return captureConsole(() =>
    worker.fetch(request, {
      GITHUB_WEBHOOK_SECRET: envSecret,
      ED25519_PRIVATE_KEY,
      POLAR_WEBHOOK_SECRET: SECRET,
      LICENSE_KV: kv,
    })
  );
}

const sponsorBody = JSON.stringify({
  action: "created",
  sponsorship: {
    sponsor: { login: "octocat", email: "octocat@example.com" },
    tier: { name: "HopTab Pro", monthly_price_in_cents: 500 },
  },
});

{
  const kv = makeKv();
  const res = await postGitHub({ secret: "gh-secret", envSecret: "gh-secret", body: sponsorBody, kv });
  check("valid GitHub sponsorship still mints a license", res.status === 200 && typeof kv.store.get("user:octocat") === "string");
}

{
  const kv = makeKv();
  const res = await postGitHub({ secret: "wrong-secret", envSecret: "gh-secret", body: sponsorBody, kv });
  check("GitHub webhook with a bad HMAC is rejected with 401", res.status === 401 && kv.counts.puts === 0);
}

{
  const kv = makeKv();
  const res = await postGitHub({ secret: null, envSecret: "gh-secret", body: sponsorBody, kv });
  check("GitHub webhook with no signature header is rejected with 401", res.status === 401 && kv.counts.puts === 0);
}

{
  const kv = makeKv();
  const res = await postGitHub({ secret: "gh-secret", envSecret: "", body: sponsorBody, kv });
  check("GitHub webhook fails closed with 500 when the secret is unset", res.status === 500 && kv.counts.puts === 0);
}

check("no log line contains the GitHub retrieval token in full", !capturedLogs.some((l) => /token: [0-9a-f]{8}-[0-9a-f]{4}/.test(l)));

// --- Result ----------------------------------------------------------------

console.log(`\n${passed} passed, ${failures.length} failed\n`);
if (failures.length > 0) {
  for (const f of failures) console.error(`  failed: ${f}`);
  process.exit(1);
}
