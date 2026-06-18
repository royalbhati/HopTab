# HopTab landing page → hoptab.app

Static site (no framework). Three files do the work:

- `index.html` — the page
- `styles.css` — all styling
- `app.js` — workflow tabs, install-command copy button, and analytics events
- `_headers` — Cloudflare cache rules
- `*.png` / `*.jpg` — screenshots (served from root)

## Deploy on Cloudflare Pages

The domain `hoptab.app` is already on Cloudflare, so this is a few clicks:

### Option A — connect the GitHub repo (recommended, auto-deploys on push)
1. Cloudflare Dashboard → **Workers & Pages** → **Create** → **Pages** → **Connect to Git**.
2. Pick the `royalbhati/HopTab` repo.
3. Build settings:
   - **Framework preset:** None
   - **Build command:** *(leave empty)*
   - **Build output directory:** `website`
4. **Save and Deploy.** You get a `*.pages.dev` URL to verify.
5. Pages project → **Custom domains** → **Set up a domain** → `hoptab.app` (and `www.hoptab.app`).
   Because the domain is already in this Cloudflare account, it adds the DNS/CNAME and SSL automatically.

### Option B — direct upload (no Git)
```bash
npm i -g wrangler
cd website
wrangler pages deploy . --project-name hoptab
```
Then add the custom domain as in step 5 above.

## Analytics / tracking

Page views + custom events flow to **Google Analytics 4** (`G-9SCWYZ03TN`, already wired) and **Umami**.
Custom events fired by `app.js` via `track(name, data)`:

| Event | Fired when |
|---|---|
| `download_click` | "Download for macOS" / GitHub Releases (`location`: hero \| install) |
| `pro_click` | any Get Pro / Sponsors button (`location`, `provider`) |
| `github_click` | GitHub / View Source links (`location`) |
| `discord_click` | Discord links (`location`) |
| `install_command_copied` | the install box Copy button |
| `workflow_view` | switching workflow tabs (`workflow`) |

In **GA4** these appear under Reports → Engagement → Events. To turn `download_click` into a
conversion: Admin → Events → mark it as a key event.

Optional: enable **Cloudflare Web Analytics** (free, cookieless) in the Pages project and paste its
beacon `<script>` into the marked slot in `index.html`'s `<head>` — events still go to GA4/Umami.

## Notes
- `royalbhati.com/hoptab` (the Next.js page) now sets its canonical URL to `https://hoptab.app/`,
  so search engines consolidate ranking onto the new domain. Consider 301-redirecting that path
  to hoptab.app once this is live.
- The OG/social image is `hoptab_highlight.jpg`. Swap in a purpose-built 1200×630 card anytime.
