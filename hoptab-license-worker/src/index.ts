/**
 * HopTab License Worker
 *
 * Handles license key generation from multiple sources:
 *   - Polar.sh checkout (primary)
 *   - GitHub Sponsors webhook (secondary)
 *   - Manual generation via success URL
 *
 * Routes:
 *   POST /webhook          — GitHub Sponsors webhook endpoint
 *   POST /polar/webhook    — Polar.sh webhook endpoint
 *   GET  /license/:token   — License key retrieval (one-time or checkout-id based)
 *
 * Secrets (set via `wrangler secret put`):
 *   GITHUB_WEBHOOK_SECRET — GitHub webhook secret (REQUIRED; /webhook fails closed without it)
 *   ED25519_PRIVATE_KEY   — Base64-encoded 32-byte Ed25519 private key
 *   RESEND_API_KEY        — Resend.com API key for email delivery (optional)
 *   POLAR_WEBHOOK_SECRET  — Polar.sh webhook secret (REQUIRED; /polar/webhook fails closed without it)
 *
 * Vars (plain text, may live in wrangler.toml):
 *   POLAR_PRODUCT_ID      — comma-separated allowlist of Polar product ids that
 *                           may mint a Pro license. Strongly recommended.
 */

import { verifyStandardWebhook } from "./webhook-verify";

interface Env {
  GITHUB_WEBHOOK_SECRET: string;
  ED25519_PRIVATE_KEY: string;
  RESEND_API_KEY?: string;
  POLAR_WEBHOOK_SECRET?: string;
  POLAR_PRODUCT_ID?: string;
  LICENSE_KV: KVNamespace;
}

/** Polar events that are allowed to mint a license. */
const POLAR_LICENSING_EVENTS = new Set(["order.created", "checkout.updated"]);

/** Minimum paid amount, in cents, that counts as a Pro purchase (mirrors the GitHub Sponsors tier check). */
const PRO_MIN_AMOUNT_CENTS = 400;

/** Webhook bodies are a few KB at most; anything larger is not a real delivery. */
const MAX_WEBHOOK_BODY_BYTES = 512 * 1024;

/** Retention for webhook idempotency markers. */
const IDEMPOTENCY_TTL_SECONDS = 30 * 24 * 60 * 60;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // GitHub Sponsors webhook
    if (request.method === "POST" && url.pathname === "/webhook") {
      try {
        return await handleGitHubWebhook(request, env);
      } catch (e) {
        console.error("GitHub webhook error:", errorLabel(e));
        return jsonResponse({ error: "Internal error" }, 500);
      }
    }

    // Polar.sh webhook
    if (request.method === "POST" && url.pathname === "/polar/webhook") {
      try {
        return await handlePolarWebhook(request, env);
      } catch (e) {
        // Never echo the exception back to the caller — it can leak internals.
        console.error("Polar webhook error:", errorLabel(e));
        return jsonResponse({ error: "Internal error" }, 500);
      }
    }

    // License retrieval — works for both one-time tokens and Polar checkout IDs
    if (request.method === "GET" && url.pathname.startsWith("/license/")) {
      const token = url.pathname.slice("/license/".length);
      return handleLicenseRetrieval(token, request, env);
    }

    return new Response("Not Found", { status: 404 });
  },
};

// --- Polar.sh Webhook Handler ---

async function handlePolarWebhook(request: Request, env: Env): Promise<Response> {
  // Fail closed. Without a secret we cannot tell a real Polar delivery from
  // anybody with curl, and this endpoint mints perpetual Pro licenses.
  const secret = (env.POLAR_WEBHOOK_SECRET ?? "").trim();
  if (secret.length === 0) {
    console.error(
      "SECURITY: POLAR_WEBHOOK_SECRET is not configured. Refusing to process Polar webhooks. " +
        "Set it with: wrangler secret put POLAR_WEBHOOK_SECRET"
    );
    return jsonResponse({ error: "Webhook verification is not configured" }, 500);
  }

  const declaredLength = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(declaredLength) && declaredLength > MAX_WEBHOOK_BODY_BYTES) {
    return new Response("Payload too large", { status: 413 });
  }

  // The signature covers the exact bytes received — read the body as text and
  // never re-serialise it before verifying.
  const body = await request.text();
  if (body.length > MAX_WEBHOOK_BODY_BYTES) {
    return new Response("Payload too large", { status: 413 });
  }

  const webhookId = request.headers.get("webhook-id");
  const webhookTimestamp = request.headers.get("webhook-timestamp");
  const webhookSignature = request.headers.get("webhook-signature");

  const verification = await verifyStandardWebhook({
    id: webhookId,
    timestamp: webhookTimestamp,
    signatureHeader: webhookSignature,
    body,
    secret,
  });

  if (!verification.ok) {
    // Log the coarse reason only — never the signature header or the secret.
    console.warn(
      `Polar webhook rejected (${verification.reason}) id=${shortId(webhookId)}`
    );
    if (verification.reason === "missing_secret") {
      return jsonResponse({ error: "Webhook verification is not configured" }, 500);
    }
    return new Response("Invalid signature", { status: 401 });
  }

  // webhook-id is part of the signed content, so it is trustworthy at this
  // point. Bound it anyway before it becomes a KV key.
  const deliveryId = (webhookId ?? "").trim();
  if (deliveryId.length === 0 || deliveryId.length > 200) {
    return new Response("Invalid webhook id", { status: 400 });
  }

  // Idempotency: Polar retries deliveries. A retry of a legitimate delivery
  // must not mint a second license or send a second email.
  const idempotencyKey = `polar:delivery:${deliveryId}`;
  const alreadyProcessed = await env.LICENSE_KV.get(idempotencyKey);
  if (alreadyProcessed) {
    console.log(`Polar webhook ${shortId(deliveryId)} already processed — ignoring replay`);
    return jsonResponse({ ok: true, idempotent: true }, 200);
  }

  let payload: any;
  try {
    payload = JSON.parse(body);
  } catch {
    return new Response("Invalid JSON body", { status: 400 });
  }

  const eventType = typeof payload?.type === "string"
    ? payload.type
    : typeof payload?.event === "string"
      ? payload.event
      : "";

  console.log(`Polar webhook verified: ${safeLabel(eventType)} id=${shortId(deliveryId)}`);

  if (!POLAR_LICENSING_EVENTS.has(eventType)) {
    return new Response("Ignored event: " + safeLabel(eventType), { status: 200 });
  }

  const checkout = (payload?.data ?? {}) as Record<string, any>;
  const status = typeof checkout.status === "string" ? checkout.status : "";

  // Only process successful checkouts
  if (status !== "succeeded" && status !== "confirmed" && eventType !== "order.created") {
    return new Response("Checkout not completed: " + safeLabel(status), { status: 200 });
  }

  // Product allowlist. Without this, any product sold through the same Polar
  // organisation (or a $0 test product) would mint a Pro license.
  const allowedProducts = parseAllowlist(env.POLAR_PRODUCT_ID);
  if (allowedProducts.length > 0) {
    const productIds = collectProductIds(checkout);
    const matches = productIds.some((id) => allowedProducts.includes(id));
    if (!matches) {
      console.warn(
        `Polar webhook rejected: product not in POLAR_PRODUCT_ID allowlist ` +
          `(saw ${productIds.map(safeLabel).join(",") || "none"}) id=${shortId(deliveryId)}`
      );
      return new Response("Product not allowed", { status: 400 });
    }
  } else {
    console.warn(
      "POLAR_PRODUCT_ID is not set — every product in this Polar org can mint a Pro license."
    );
  }

  // Mirror the GitHub Sponsors tier check: below the Pro price and not named
  // "pro" means this is not a Pro purchase.
  const amountCents = firstNumber(
    checkout.amount,
    checkout.total_amount,
    checkout.subtotal_amount,
    checkout.net_amount,
    checkout.product_price?.price_amount
  );
  const productName = firstString(checkout.product?.name, checkout.product_name) ?? "";
  if (amountCents !== null && amountCents < PRO_MIN_AMOUNT_CENTS && !productName.toLowerCase().includes("pro")) {
    console.warn(`Polar webhook ignored: not a Pro purchase id=${shortId(deliveryId)}`);
    return new Response("Not a Pro tier purchase", { status: 200 });
  }

  const email = firstString(checkout.customer_email, checkout.customer?.email);
  const name = firstString(checkout.customer_name, checkout.customer?.name) ?? "polar-user";
  const checkoutId = firstString(checkout.id);

  // Generate the license key
  const licenseKey = await generateLicenseKey(name, email, env.ED25519_PRIVATE_KEY);

  // Store by checkout ID (so the success URL redirect can retrieve it)
  if (checkoutId && isSafeKvToken(checkoutId)) {
    await env.LICENSE_KV.put(`checkout:${checkoutId}`, licenseKey, { expirationTtl: 30 * 24 * 60 * 60 });
  } else if (checkoutId) {
    console.warn(`Polar checkout id has an unexpected shape — skipping checkout KV write id=${shortId(deliveryId)}`);
  }

  // Store permanently by email for support/re-issue
  if (email && isPlausibleEmail(email)) {
    await env.LICENSE_KV.put(`email:${email}`, licenseKey);
  }

  // Send email if Resend is configured
  if (env.RESEND_API_KEY && email) {
    await sendLicenseEmail(email, name, licenseKey, env.RESEND_API_KEY);
  }

  // Mark the delivery as processed only once the license actually exists, so a
  // failed run is still retryable by Polar.
  await env.LICENSE_KV.put(
    idempotencyKey,
    JSON.stringify({ at: Date.now(), checkout: checkoutId ?? null }),
    { expirationTtl: IDEMPOTENCY_TTL_SECONDS }
  );

  console.log(
    `Polar license generated for ${maskEmail(email)}, checkout: ${shortId(checkoutId)}, key: ${shortId(licenseKey)}`
  );
  return jsonResponse({ ok: true }, 200);
}

// --- GitHub Sponsors Webhook Handler ---

async function handleGitHubWebhook(request: Request, env: Env): Promise<Response> {
  const secret = (env.GITHUB_WEBHOOK_SECRET ?? "").trim();
  if (secret.length === 0) {
    console.error(
      "SECURITY: GITHUB_WEBHOOK_SECRET is not configured. Refusing to process GitHub webhooks. " +
        "Set it with: wrangler secret put GITHUB_WEBHOOK_SECRET"
    );
    return jsonResponse({ error: "Webhook verification is not configured" }, 500);
  }

  const declaredLength = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(declaredLength) && declaredLength > MAX_WEBHOOK_BODY_BYTES) {
    return new Response("Payload too large", { status: 413 });
  }

  const body = await request.text();
  if (body.length > MAX_WEBHOOK_BODY_BYTES) {
    return new Response("Payload too large", { status: 413 });
  }

  // Verify GitHub webhook signature
  const signature = request.headers.get("x-hub-signature-256") || "";
  const isValid = await verifyGitHubSignature(body, signature, secret);
  if (!isValid) {
    return new Response("Invalid signature", { status: 401 });
  }

  const event = request.headers.get("x-github-event");
  if (event !== "sponsorship") {
    return new Response("Ignored event: " + safeLabel(event), { status: 200 });
  }

  let payload: any;
  try {
    payload = JSON.parse(body);
  } catch {
    return new Response("Invalid JSON body", { status: 400 });
  }
  const action = payload.action;

  if (action !== "created") {
    return new Response("Ignored action: " + safeLabel(action), { status: 200 });
  }

  const sponsor = payload.sponsorship?.sponsor;
  const tier = payload.sponsorship?.tier;

  if (!sponsor || !tier) {
    return new Response("Missing sponsor/tier data", { status: 400 });
  }

  const username = sponsor.login as string;
  const email = (sponsor.email as string) || null;
  const tierName = String(tier.name ?? "");

  const monthlyAmount = tier.monthly_price_in_cents as number;
  if (monthlyAmount < PRO_MIN_AMOUNT_CENTS && !tierName.toLowerCase().includes("pro")) {
    return new Response("Not a Pro tier sponsorship", { status: 200 });
  }

  // Idempotency: GitHub retries deliveries and re-delivers on demand.
  const deliveryId = (request.headers.get("x-github-delivery") ?? "").trim();
  if (deliveryId && deliveryId.length <= 200) {
    const seen = await env.LICENSE_KV.get(`github:delivery:${deliveryId}`);
    if (seen) {
      console.log(`GitHub webhook ${shortId(deliveryId)} already processed — ignoring replay`);
      return jsonResponse({ ok: true, idempotent: true }, 200);
    }
  }

  const licenseKey = await generateLicenseKey(username, email, env.ED25519_PRIVATE_KEY);

  // Store with a retrieval token
  const retrievalToken = crypto.randomUUID();
  await env.LICENSE_KV.put(retrievalToken, licenseKey, { expirationTtl: 7 * 24 * 60 * 60 });
  // GitHub usernames are 1-39 chars of [A-Za-z0-9-]; anything else is not a real login.
  if (/^[A-Za-z0-9-]{1,39}$/.test(username)) {
    await env.LICENSE_KV.put(`user:${username}`, licenseKey);
  }

  if (env.RESEND_API_KEY && email) {
    await sendLicenseEmail(email, username, licenseKey, env.RESEND_API_KEY);
  }

  if (deliveryId && deliveryId.length <= 200) {
    await env.LICENSE_KV.put(
      `github:delivery:${deliveryId}`,
      JSON.stringify({ at: Date.now() }),
      { expirationTtl: IDEMPOTENCY_TTL_SECONDS }
    );
  }

  // The retrieval token is a bearer credential — log a prefix only.
  console.log(`GitHub license generated for @${safeLabel(username)} (token: ${shortId(retrievalToken)})`);
  return jsonResponse({ ok: true, token: retrievalToken }, 200);
}

// --- License Retrieval ---

/**
 * Best-effort per-IP throttle for /license/<token>.
 *
 * Held in isolate memory rather than KV: it costs nothing, it cannot exhaust
 * the KV write quota that license minting depends on, and — like Cloudflare's
 * own rate limiting — it is per-colo rather than global. Tokens are UUIDs and
 * Polar checkout ids are UUIDs, so this is defence in depth against scripted
 * enumeration, not the primary control.
 */
const RATE_LIMIT_WINDOW_MS = 60_000;
const RATE_LIMIT_MAX_REQUESTS = 60; // the "still generating" page auto-refreshes every 5s (12/min)
const RATE_LIMIT_MAX_TRACKED_CLIENTS = 10_000;
const licenseLookupCounters = new Map<string, { count: number; windowStart: number }>();

function licenseLookupAllowed(request: Request): boolean {
  const client = request.headers.get("cf-connecting-ip") || "unknown";
  const now = Date.now();

  if (licenseLookupCounters.size > RATE_LIMIT_MAX_TRACKED_CLIENTS) {
    licenseLookupCounters.clear();
  }

  const entry = licenseLookupCounters.get(client);
  if (!entry || now - entry.windowStart >= RATE_LIMIT_WINDOW_MS) {
    licenseLookupCounters.set(client, { count: 1, windowStart: now });
    return true;
  }

  entry.count += 1;
  return entry.count <= RATE_LIMIT_MAX_REQUESTS;
}

/**
 * Tokens are either `crypto.randomUUID()` or a Polar checkout/order id. Both
 * are URL-safe. Enforcing the shape stops `/license/email:someone@example.com`
 * and `/license/user:someone` from reading the permanent, non-expiring KV
 * entries that live in the same namespace.
 */
function isSafeKvToken(token: string): boolean {
  return /^[A-Za-z0-9_-]{8,128}$/.test(token);
}

async function handleLicenseRetrieval(rawToken: string, request: Request, env: Env): Promise<Response> {
  if (!rawToken) {
    return new Response("Missing token", { status: 400 });
  }

  let token = rawToken;
  try {
    token = decodeURIComponent(rawToken);
  } catch {
    // Malformed percent-encoding — fall through to the shape check below.
  }

  if (!isSafeKvToken(token)) {
    return new Response("Invalid token", { status: 400 });
  }

  if (!licenseLookupAllowed(request)) {
    return new Response("Too many requests", {
      status: 429,
      headers: { "Retry-After": "60", "Cache-Control": "no-store" },
    });
  }

  // Try checkout ID first (Polar.sh success URL uses checkout ID)
  let licenseKey = await env.LICENSE_KV.get(`checkout:${token}`);

  // Fall back to direct token (GitHub Sponsors)
  if (!licenseKey) {
    licenseKey = await env.LICENSE_KV.get(token);
    // Delete one-time tokens after retrieval
    if (licenseKey) {
      await env.LICENSE_KV.delete(token);
    }
  }

  if (!licenseKey) {
    // License might not be generated yet (Polar webhook can be delayed)
    return htmlResponse(
      htmlPage(
        "Thank You for Purchasing HopTab Pro!",
        `<p>Your license key is being generated. This usually takes a few seconds.</p>
         <p><strong>This page will refresh automatically.</strong></p>
         <p>We're also sending the license key to your email. If you don't see it in a minute, check your spam folder.</p>

         <div style="background:#f8f8f8;padding:20px;border-radius:8px;margin:24px 0;">
           <h3 style="font-size:15px;margin-bottom:12px;">While you wait:</h3>
           <p style="margin-bottom:8px;"><strong>1. Download HopTab</strong> if you haven't already:</p>
           <a href="https://github.com/royalbhati/HopTab/releases/latest" style="display:inline-block;padding:8px 20px;background:#000;color:#fff;text-decoration:none;font-size:13px;font-weight:600;border-radius:4px;">Download for macOS</a>
           <p style="margin-top:12px;"><strong>2.</strong> Open HopTab Settings → <strong>Pro</strong> tab</p>
           <p><strong>3.</strong> Paste your license key and click <strong>Activate</strong></p>
         </div>

         <p style="color:#888;font-size:13px;">Didn't receive the email? Contact <a href="mailto:rawyelll@gmail.com">rawyelll@gmail.com</a> and I'll sort it out.</p>
         <script>setTimeout(() => location.reload(), 5000);</script>`
      )
    );
  }

  return htmlResponse(
    htmlPage(
      "Thank You for Purchasing HopTab Pro!",
      `<p style="font-size:15px;margin-bottom:20px;">Your license key is ready.</p>

       <div style="background:#1a1a2e;color:#e0e0e0;padding:16px;border-radius:8px;font-family:monospace;font-size:13px;word-break:break-all;margin:0 0 20px;user-select:all;cursor:text;">
         ${licenseKey}
       </div>

       <div style="background:#f8f8f8;padding:20px;border-radius:8px;margin-bottom:20px;">
         <h3 style="font-size:15px;margin-bottom:12px;">How to activate:</h3>
         <p style="margin-bottom:8px;"><strong>1. Download HopTab</strong> if you haven't already:</p>
         <a href="https://github.com/royalbhati/HopTab/releases/latest" style="display:inline-block;padding:8px 20px;background:#000;color:#fff;text-decoration:none;font-size:13px;font-weight:600;border-radius:4px;margin-bottom:8px;">Download for macOS</a>
         <p style="margin-top:12px;"><strong>2.</strong> Open HopTab → click the menu bar icon → <strong>Settings</strong></p>
         <p><strong>3.</strong> Go to the <strong>Pro</strong> tab in the sidebar</p>
         <p><strong>4.</strong> Paste the license key above and click <strong>Activate</strong></p>
       </div>

       <p style="color:#888;font-size:13px;">We also sent this key to your email. Save it somewhere safe — you can use it on any Mac you own.</p>
       <p style="color:#888;font-size:13px;">Having trouble? Email <a href="mailto:rawyelll@gmail.com">rawyelll@gmail.com</a> and I'll help.</p>`
    )
  );
}

// --- License Key Generation ---

async function generateLicenseKey(
  username: string,
  email: string | null,
  privateKeyBase64: string
): Promise<string> {
  const payload = {
    sub: username,
    email: email,
    iat: Math.floor(Date.now() / 1000),
    tier: "pro",
    app: "hoptab",
  };

  const payloadBytes = new TextEncoder().encode(JSON.stringify(payload));
  const payloadBase64 = btoa(String.fromCharCode(...payloadBytes));

  try {
    // Try Ed25519 signing (supported in newer Workers runtime)
    const privateKeyBytes = Uint8Array.from(atob(privateKeyBase64), (c) => c.charCodeAt(0));

    // Ed25519 in Web Crypto uses PKCS8 format, but we have raw 32 bytes.
    // Build a PKCS8 wrapper for the Ed25519 private key.
    const pkcs8Prefix = new Uint8Array([
      0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06,
      0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
    ]);
    const pkcs8Key = new Uint8Array(pkcs8Prefix.length + privateKeyBytes.length);
    pkcs8Key.set(pkcs8Prefix);
    pkcs8Key.set(privateKeyBytes, pkcs8Prefix.length);

    const privateKey = await crypto.subtle.importKey(
      "pkcs8",
      pkcs8Key,
      { name: "Ed25519" },
      false,
      ["sign"]
    );

    const signature = await crypto.subtle.sign("Ed25519", privateKey, payloadBytes);
    const signatureBase64 = btoa(String.fromCharCode(...new Uint8Array(signature)));
    return `${payloadBase64}.${signatureBase64}.1`;
  } catch (e) {
    // Fallback: try raw import (some runtimes support it)
    try {
      const privateKeyBytes = Uint8Array.from(atob(privateKeyBase64), (c) => c.charCodeAt(0));
      const privateKey = await crypto.subtle.importKey(
        "raw",
        privateKeyBytes,
        { name: "Ed25519" },
        false,
        ["sign"]
      );
      const signature = await crypto.subtle.sign("Ed25519", privateKey, payloadBytes);
      const signatureBase64 = btoa(String.fromCharCode(...new Uint8Array(signature)));
      return `${payloadBase64}.${signatureBase64}.1`;
    } catch (e2) {
      console.error("Ed25519 signing failed:", errorLabel(e), errorLabel(e2));
      throw new Error("License key generation failed — Ed25519 not supported in this runtime");
    }
  }
}

// --- GitHub Webhook Verification ---

async function verifyGitHubSignature(
  body: string,
  signatureHeader: string,
  secret: string
): Promise<boolean> {
  if (!secret || !signatureHeader.startsWith("sha256=")) return false;

  const expectedSig = signatureHeader.slice("sha256=".length).trim();
  // HMAC-SHA256 is 32 bytes = 64 hex characters.
  if (!/^[0-9a-fA-F]{64}$/.test(expectedSig)) return false;

  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"]
  );

  const sigBytes = hexToBytes(expectedSig);

  return crypto.subtle.verify("HMAC", key, sigBytes, encoder.encode(body));
}

function hexToBytes(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = parseInt(hex.substring(i, i + 2), 16);
  }
  return bytes;
}

// --- Payload helpers (defensive: Polar payload shapes differ per event) ---

function parseAllowlist(value: string | undefined): string[] {
  if (!value) return [];
  return value
    .split(",")
    .map((v) => v.trim())
    .filter((v) => v.length > 0);
}

/** Every place a Polar payload might carry the purchased product id. */
function collectProductIds(data: Record<string, any>): string[] {
  const ids: string[] = [];
  const push = (v: unknown) => {
    if (typeof v === "string" && v.length > 0 && !ids.includes(v)) ids.push(v);
  };

  push(data.product_id);
  push(data.product?.id);
  push(data.productId);
  push(data.subscription?.product_id);
  push(data.checkout?.product_id);
  push(data.product_price?.product_id);

  const items = Array.isArray(data.items) ? data.items : [];
  for (const item of items) {
    push(item?.product_id);
    push(item?.product?.id);
    push(item?.product_price?.product_id);
  }

  const products = Array.isArray(data.products) ? data.products : [];
  for (const product of products) {
    push(product?.id);
  }

  return ids;
}

function firstString(...values: unknown[]): string | null {
  for (const value of values) {
    if (typeof value === "string" && value.trim().length > 0) return value;
  }
  return null;
}

function firstNumber(...values: unknown[]): number | null {
  for (const value of values) {
    if (typeof value === "number" && Number.isFinite(value)) return value;
  }
  return null;
}

function isPlausibleEmail(email: string): boolean {
  return email.length <= 320 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

// --- Logging / response helpers ---

/** First few characters only — used for ids, tokens and license keys. */
function shortId(value: string | null | undefined): string {
  if (!value) return "none";
  return value.length <= 8 ? value : `${value.slice(0, 8)}…`;
}

function maskEmail(email: string | null): string {
  if (!email) return "no-email";
  const at = email.indexOf("@");
  if (at <= 0) return "***";
  return `${email.slice(0, Math.min(2, at))}***@${email.slice(at + 1)}`;
}

/** Strip anything that is not a plain identifier before echoing or logging. */
function safeLabel(value: unknown): string {
  return String(value ?? "").replace(/[^A-Za-z0-9._-]/g, "").slice(0, 64);
}

function errorLabel(e: unknown): string {
  if (e instanceof Error) return e.name + ": " + e.message.slice(0, 200);
  return safeLabel(e);
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

function htmlResponse(html: string): Response {
  return new Response(html, {
    status: 200,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      // The page contains a license key — keep it out of every shared cache.
      "Cache-Control": "no-store, private",
      "X-Content-Type-Options": "nosniff",
      "Referrer-Policy": "no-referrer",
    },
  });
}

// --- Email ---

async function sendLicenseEmail(
  email: string,
  username: string,
  licenseKey: string,
  resendApiKey: string
): Promise<void> {
  try {
    await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${resendApiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: "HopTab <noreply@royalbhati.com>",
        to: email,
        subject: "Your HopTab Pro License Key",
        html: `
          <div style="font-family:-apple-system,sans-serif;max-width:500px;margin:0 auto;color:#333;">
            <h2 style="margin-bottom:16px;">Thanks for purchasing HopTab Pro!</h2>

            <p>Here's your license key:</p>
            <div style="background:#1a1a2e;color:#e0e0e0;padding:16px;border-radius:8px;font-family:monospace;font-size:13px;word-break:break-all;margin:16px 0;">
              ${licenseKey}
            </div>

            <div style="background:#f8f8f8;padding:20px;border-radius:8px;margin:20px 0;">
              <h3 style="font-size:15px;margin-bottom:12px;">How to activate:</h3>
              <p style="margin-bottom:8px;"><strong>1. Download HopTab</strong> if you haven't already:</p>
              <a href="https://github.com/royalbhati/HopTab/releases/latest" style="display:inline-block;padding:8px 20px;background:#000;color:#fff;text-decoration:none;font-size:13px;font-weight:600;border-radius:4px;">Download for macOS</a>
              <p style="margin-top:12px;"><strong>2.</strong> Open HopTab → menu bar icon → Settings</p>
              <p><strong>3.</strong> Go to the <strong>Pro</strong> tab in the sidebar</p>
              <p><strong>4.</strong> Paste the license key and click <strong>Activate</strong></p>
            </div>

            <p style="color:#888;font-size:13px;">Keep this key safe — you can use it on any Mac you own.</p>
            <p style="color:#888;font-size:12px;">Having trouble? Reply to this email or contact <a href="mailto:rawyelll@gmail.com">rawyelll@gmail.com</a></p>
            <p style="color:#aaa;font-size:11px;margin-top:20px;">Learn more at <a href="https://www.royalbhati.com/hoptab" style="color:#aaa;">royalbhati.com/hoptab</a></p>
          </div>
        `,
      }),
    });
  } catch (e) {
    console.error("Failed to send email:", errorLabel(e));
  }
}

// --- HTML Template ---

function htmlPage(title: string, content: string): string {
  return `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${title} — HopTab</title>
  <style>
    body { font-family: -apple-system, sans-serif; max-width: 560px; margin: 60px auto; padding: 20px; color: #333; }
    h1 { font-size: 22px; margin-bottom: 16px; }
    a { color: #007AFF; }
  </style>
</head>
<body>
  <h1>${title}</h1>
  ${content}
</body>
</html>`;
}
