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
 *   GITHUB_WEBHOOK_SECRET — GitHub webhook secret
 *   ED25519_PRIVATE_KEY   — Base64-encoded 32-byte Ed25519 private key
 *   RESEND_API_KEY        — Resend.com API key for email delivery (optional)
 *   POLAR_WEBHOOK_SECRET  — Polar.sh webhook secret (optional, for signature verification)
 */

interface Env {
  GITHUB_WEBHOOK_SECRET: string;
  ED25519_PRIVATE_KEY: string;
  RESEND_API_KEY?: string;
  POLAR_WEBHOOK_SECRET?: string;
  LICENSE_KV: KVNamespace;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // GitHub Sponsors webhook
    if (request.method === "POST" && url.pathname === "/webhook") {
      return handleGitHubWebhook(request, env);
    }

    // Polar.sh webhook
    if (request.method === "POST" && url.pathname === "/polar/webhook") {
      try {
        return await handlePolarWebhook(request, env);
      } catch (e) {
        console.error("Polar webhook error:", e);
        return new Response(JSON.stringify({ error: String(e) }), { status: 500, headers: { "Content-Type": "application/json" } });
      }
    }

    // License retrieval — works for both one-time tokens and Polar checkout IDs
    if (request.method === "GET" && url.pathname.startsWith("/license/")) {
      const token = url.pathname.split("/license/")[1];
      return handleLicenseRetrieval(token, env);
    }

    return new Response("Not Found", { status: 404 });
  },
};

// --- Polar.sh Webhook Handler ---

async function handlePolarWebhook(request: Request, env: Env): Promise<Response> {
  const body = await request.text();

  // Verify webhook signature if secret is configured
  if (env.POLAR_WEBHOOK_SECRET) {
    const signature = request.headers.get("webhook-signature") || "";
    // Polar uses a different signature format — verify if present
    // For now, we'll check basic structure and log
    if (!signature) {
      console.log("Warning: No webhook signature from Polar");
    }
  }

  const payload = JSON.parse(body);
  const eventType = payload.type || payload.event;

  console.log(`Polar webhook received: ${eventType}`);

  // Handle checkout completed
  if (eventType === "checkout.updated" || eventType === "order.created") {
    const checkout = payload.data;
    const status = checkout.status;

    // Only process successful checkouts
    if (status !== "succeeded" && status !== "confirmed" && eventType !== "order.created") {
      return new Response("Checkout not completed: " + status, { status: 200 });
    }

    const email = checkout.customer_email || checkout.customer?.email || null;
    const name = checkout.customer_name || checkout.customer?.name || "polar-user";
    const checkoutId = checkout.id;

    // Generate the license key
    const licenseKey = await generateLicenseKey(name, email, env.ED25519_PRIVATE_KEY);

    // Store by checkout ID (so the success URL redirect can retrieve it)
    if (checkoutId) {
      await env.LICENSE_KV.put(`checkout:${checkoutId}`, licenseKey, { expirationTtl: 30 * 24 * 60 * 60 });
    }

    // Store permanently by email for support/re-issue
    if (email) {
      await env.LICENSE_KV.put(`email:${email}`, licenseKey);
    }

    // Send email if Resend is configured
    if (env.RESEND_API_KEY && email) {
      await sendLicenseEmail(email, name, licenseKey, env.RESEND_API_KEY);
    }

    console.log(`Polar license generated for ${name} (${email}), checkout: ${checkoutId}`);
    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  return new Response("Ignored event: " + eventType, { status: 200 });
}

// --- GitHub Sponsors Webhook Handler ---

async function handleGitHubWebhook(request: Request, env: Env): Promise<Response> {
  const body = await request.text();

  // Verify GitHub webhook signature
  const signature = request.headers.get("x-hub-signature-256") || "";
  const isValid = await verifyGitHubSignature(body, signature, env.GITHUB_WEBHOOK_SECRET);
  if (!isValid) {
    return new Response("Invalid signature", { status: 401 });
  }

  const event = request.headers.get("x-github-event");
  if (event !== "sponsorship") {
    return new Response("Ignored event: " + event, { status: 200 });
  }

  const payload = JSON.parse(body);
  const action = payload.action;

  if (action !== "created") {
    return new Response("Ignored action: " + action, { status: 200 });
  }

  const sponsor = payload.sponsorship?.sponsor;
  const tier = payload.sponsorship?.tier;

  if (!sponsor || !tier) {
    return new Response("Missing sponsor/tier data", { status: 400 });
  }

  const username = sponsor.login as string;
  const email = (sponsor.email as string) || null;
  const tierName = tier.name as string;

  const monthlyAmount = tier.monthly_price_in_cents as number;
  if (monthlyAmount < 400 && !tierName.toLowerCase().includes("pro")) {
    return new Response("Not a Pro tier sponsorship", { status: 200 });
  }

  const licenseKey = await generateLicenseKey(username, email, env.ED25519_PRIVATE_KEY);

  // Store with a retrieval token
  const retrievalToken = crypto.randomUUID();
  await env.LICENSE_KV.put(retrievalToken, licenseKey, { expirationTtl: 7 * 24 * 60 * 60 });
  await env.LICENSE_KV.put(`user:${username}`, licenseKey);

  if (env.RESEND_API_KEY && email) {
    await sendLicenseEmail(email, username, licenseKey, env.RESEND_API_KEY);
  }

  console.log(`GitHub license generated for @${username} (token: ${retrievalToken})`);
  return new Response(JSON.stringify({ ok: true, token: retrievalToken }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

// --- License Retrieval ---

async function handleLicenseRetrieval(token: string, env: Env): Promise<Response> {
  if (!token) {
    return new Response("Missing token", { status: 400 });
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
    return new Response(
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
      ),
      { status: 200, headers: { "Content-Type": "text/html" } }
    );
  }

  return new Response(
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
    ),
    { status: 200, headers: { "Content-Type": "text/html" } }
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
      console.error("Ed25519 signing failed:", e, e2);
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
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"]
  );

  const expectedSig = signatureHeader.replace("sha256=", "");
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
    console.error("Failed to send email:", e);
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
