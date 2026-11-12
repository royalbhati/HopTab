/**
 * Standard Webhooks (https://www.standardwebhooks.com) signature verification.
 *
 * Polar.sh signs every webhook delivery with this spec:
 *   headers: webhook-id, webhook-timestamp, webhook-signature
 *   signed content: `${webhook-id}.${webhook-timestamp}.${rawBody}`
 *   webhook-signature: space separated `v1,<base64 HMAC-SHA256>` entries
 *                      (several entries can be present during key rotation —
 *                       the delivery is authentic if ANY of them matches)
 *
 * This lives in its own module so it can be exercised outside the Workers
 * runtime — see ../scripts/verify-signature-check.mjs.
 */

/** Reject deliveries whose timestamp is further than this from "now". */
export const WEBHOOK_TOLERANCE_SECONDS = 300; // 5 minutes

export type WebhookVerificationFailure =
  | "missing_secret"
  | "missing_headers"
  | "bad_timestamp"
  | "timestamp_out_of_tolerance"
  | "malformed_signature_header"
  | "signature_mismatch";

export interface WebhookVerificationResult {
  ok: boolean;
  /** Coarse machine-readable reason. Safe to log — never contains secret material. */
  reason?: WebhookVerificationFailure;
}

export interface VerifyStandardWebhookOptions {
  id: string | null | undefined;
  timestamp: string | null | undefined;
  signatureHeader: string | null | undefined;
  /** The raw request body, exactly as received — re-serialised JSON will not match. */
  body: string;
  secret: string | null | undefined;
  /** Unix seconds; defaults to the current clock. Injectable for tests. */
  nowSeconds?: number;
  toleranceSeconds?: number;
}

/**
 * Constant-time byte comparison. Never short-circuits on the first differing
 * byte, so the time taken does not leak how much of a forged signature was
 * correct. Length differences are folded into the same accumulator.
 */
export function timingSafeEqual(a: Uint8Array, b: Uint8Array): boolean {
  let diff = a.length ^ b.length;
  const len = Math.max(a.length, b.length);
  for (let i = 0; i < len; i++) {
    const av = i < a.length ? a[i] : 0;
    const bv = i < b.length ? b[i] : 0;
    diff |= av ^ bv;
  }
  return diff === 0;
}

/** Lenient base64 (also accepts base64url and missing padding). Returns null if it is not base64. */
export function base64ToBytes(input: string): Uint8Array | null {
  const cleaned = input.trim().replace(/\s+/g, "").replace(/-/g, "+").replace(/_/g, "/");
  if (cleaned.length === 0) return null;
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(cleaned)) return null;
  const padded = cleaned.padEnd(Math.ceil(cleaned.length / 4) * 4, "=");
  try {
    const binary = atob(padded);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  } catch {
    return null;
  }
}

/**
 * Derive the raw HMAC key(s) from a configured webhook secret.
 *
 * Standard Webhooks secrets are `whsec_<base64>`: strip the prefix and
 * base64-decode. Polar has historically also handed out plain (non-base64)
 * secrets, so the raw UTF-8 bytes are kept as a second candidate. Trying both
 * costs one extra HMAC and loses nothing: a forger still has to produce a
 * signature under one of the real keys.
 */
export function webhookSecretKeyCandidates(secret: string): Uint8Array[] {
  const trimmed = secret.trim();
  const material = trimmed.startsWith("whsec_") ? trimmed.slice("whsec_".length) : trimmed;
  if (material.length === 0) return [];

  const candidates: Uint8Array[] = [];
  const decoded = base64ToBytes(material);
  if (decoded && decoded.length > 0) candidates.push(decoded);

  const raw = new TextEncoder().encode(material);
  if (raw.length > 0 && !candidates.some((c) => timingSafeEqual(c, raw))) candidates.push(raw);

  return candidates;
}

/** Pull the base64-decoded `v1,...` signatures out of a webhook-signature header. */
export function parseSignatureHeader(header: string): Uint8Array[] {
  const out: Uint8Array[] = [];
  for (const entry of header.trim().split(/\s+/)) {
    const comma = entry.indexOf(",");
    if (comma < 0) continue;
    if (entry.slice(0, comma) !== "v1") continue;
    const bytes = base64ToBytes(entry.slice(comma + 1));
    if (bytes && bytes.length > 0) out.push(bytes);
  }
  return out;
}

async function hmacSha256(key: Uint8Array, message: string): Promise<Uint8Array> {
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    key,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign("HMAC", cryptoKey, new TextEncoder().encode(message));
  return new Uint8Array(signature);
}

/**
 * Verify a Standard Webhooks delivery. Fails closed on every error path —
 * there is no code path that returns `ok: true` without an HMAC match.
 */
export async function verifyStandardWebhook(
  opts: VerifyStandardWebhookOptions
): Promise<WebhookVerificationResult> {
  const secret = (opts.secret ?? "").trim();
  if (secret.length === 0) return { ok: false, reason: "missing_secret" };

  const id = (opts.id ?? "").trim();
  const timestamp = (opts.timestamp ?? "").trim();
  const signatureHeader = (opts.signatureHeader ?? "").trim();
  if (id.length === 0 || timestamp.length === 0 || signatureHeader.length === 0) {
    return { ok: false, reason: "missing_headers" };
  }

  // Replay protection: the timestamp is part of the signed content, so an
  // attacker cannot move it without invalidating the signature.
  if (!/^\d{1,15}$/.test(timestamp)) return { ok: false, reason: "bad_timestamp" };
  const sentAt = Number(timestamp);
  if (!Number.isFinite(sentAt)) return { ok: false, reason: "bad_timestamp" };
  const now = opts.nowSeconds ?? Math.floor(Date.now() / 1000);
  const tolerance = opts.toleranceSeconds ?? WEBHOOK_TOLERANCE_SECONDS;
  if (Math.abs(now - sentAt) > tolerance) {
    return { ok: false, reason: "timestamp_out_of_tolerance" };
  }

  const provided = parseSignatureHeader(signatureHeader);
  if (provided.length === 0) return { ok: false, reason: "malformed_signature_header" };

  const keys = webhookSecretKeyCandidates(secret);
  if (keys.length === 0) return { ok: false, reason: "missing_secret" };

  const signedContent = `${id}.${timestamp}.${opts.body}`;

  // Deliberately compares every candidate without short-circuiting.
  let matched = false;
  for (const key of keys) {
    const expected = await hmacSha256(key, signedContent);
    for (const candidate of provided) {
      matched = timingSafeEqual(expected, candidate) || matched;
    }
  }

  return matched ? { ok: true } : { ok: false, reason: "signature_mismatch" };
}
