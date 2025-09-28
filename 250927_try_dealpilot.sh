#!/usr/bin/env bash
set -euo pipefail

# -------------------------
# Package + basic config
# -------------------------
cat > package.json <<'EOF'
{
  "name": "dealpilot",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "dev": "node server.js"
  },
  "dependencies": {
    "cors": "^2.8.5",
    "dotenv": "^16.4.5",
    "express": "^4.19.2",
    "openai": "^4.56.0"
  }
}
EOF

cat > .env.example <<'EOF'
# === Required ===
OPENAI_API_KEY=sk-...
BROWSERUSE_API_KEY=bu-...

# Base URL for Browser-use Cloud (see docs: https://docs.browser-use.com/)
# For Cloud:
BROWSERUSE_BASE_URL=https://api.browser-use.com
# Optional: override tasks endpoint path if your plan/cluster differs
BROWSERUSE_TASKS_PATH=/api/v1/tasks

# CORS (frontend served by this server, so usually fine)
PORT=3000
EOF

cat > .gitignore <<'EOF'
node_modules
.env
EOF

# -------------------------
# Server (API + static UI)
# -------------------------
cat > server.js <<'EOF'
import express from "express";
import cors from "cors";
import dotenv from "dotenv";
import path from "path";
import { fileURLToPath } from "url";
import OpenAI from "openai";

dotenv.config();
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const PORT = process.env.PORT || 3000;
const OPENAI_API_KEY = process.env.OPENAI_API_KEY || "";
const BROWSERUSE_API_KEY = process.env.BROWSERUSE_API_KEY || "";
const BROWSERUSE_BASE_URL = (process.env.BROWSERUSE_BASE_URL || "https://api.browser-use.com").replace(/\/+$/,"");
const BROWSERUSE_TASKS_PATH = process.env.BROWSERUSE_TASKS_PATH || "/api/v1/tasks";

if (!OPENAI_API_KEY) {
  console.error("Missing OPENAI_API_KEY in .env");
}
if (!BROWSERUSE_API_KEY) {
  console.error("Missing BROWSERUSE_API_KEY in .env");
}

const app = express();
app.use(cors());
app.use(express.json({ limit: "1mb" }));
app.use(express.static(path.join(__dirname, "public")));

const openai = new OpenAI({ apiKey: OPENAI_API_KEY });

/**
 * POST /api/find-and-buy
 * body: { query: "Huggies baby diaper size 4" }
 * returns: { best, candidates, checkout: { finalPrice, checkoutUrl } }
 */
app.post("/api/find-and-buy", async (req, res) => {
  try {
    const { query } = req.body || {};
    if (!query || typeof query !== "string") {
      return res.status(400).json({ error: "Missing 'query' string" });
    }

    // 1) Ask ChatGPT to propose candidate retailer offers with pack sizes + base prices
    const sys = `You output structured JSON only.
Given a product query, return top 3 retailer offers for the US market with:
- retailer (string)
- productUrl (string, canonical, directly add-to-cart friendly if possible)
- packSize (integer, count of units e.g., diapers)
- basePrice (number, pre-tax subtotal)
Do not include commentary.`;

    const user = `Product query: "${query}"
Return strictly valid JSON array with up to 3 items.`;

    const chat = await openai.chat.completions.create({
      model: "gpt-4o-mini",
      temperature: 0.2,
      messages: [
        { role: "system", content: sys },
        { role: "user", content: user }
      ],
      response_format: { type: "json_object" } // fallbacks to JSON parsing; some SDKs use "json_schema"
    });

    // Parse JSON robustly
    let candidates = [];
    try {
      const raw = chat.choices?.[0]?.message?.content || "[]";
      // When using response_format, some SDKs return a wrapped object; normalize:
      const parsed = JSON.parse(raw);
      candidates = Array.isArray(parsed) ? parsed : (parsed.items || parsed.results || []);
    } catch {
      candidates = [];
    }

    if (!Array.isArray(candidates) || candidates.length === 0) {
      return res.status(502).json({ error: "LLM returned no candidates" });
    }

    // 2) Compute best per-unit offer from LLM (pre-verification)
    const withUnits = candidates
      .filter(c => Number.isFinite(c.basePrice) && Number.isFinite(c.packSize) && c.packSize > 0)
      .map(c => ({ ...c, unitPrice: c.basePrice / c.packSize }));
    if (withUnits.length === 0) {
      return res.status(502).json({ error: "Candidates missing price/packSize" });
    }
    withUnits.sort((a, b) => a.unitPrice - b.unitPrice);
    const best = withUnits[0];

    // 3) Ask Browser-use to navigate to best.productUrl, add to cart, go to checkout,
    // read the final total (pre-Place-Order), and return checkout URL.
    // NOTE: This uses the Cloud REST pattern documented at docs.browser-use.com.
    // Some accounts expose different paths—override via BROWSERUSE_TASKS_PATH if needed.

    const instructions = `
Go to: ${best.productUrl}
If a size/variant is required, choose the correct variant for: ${query}
Add 1 item to cart.
Navigate to checkout page.
Read the final order total (including shipping & taxes, if visible).
IMPORTANT: Do NOT click "Place order". Stop before payment.
Return a compact JSON report with keys:
{ "finalPrice": number, "checkoutUrl": string }
`;

    const buResp = await fetch(`${BROWSERUSE_BASE_URL}${BROWSERUSE_TASKS_PATH}`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${BROWSERUSE_API_KEY}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        // Many Browser-use deployments accept a "prompt" or "instructions" field.
        // If your cluster expects a different shape (e.g., { task: {...} }), adjust here.
        instructions,
        // Optional knobs your account may support:
        maxSteps: 20,
        returnJson: true
      })
    });

    if (!buResp.ok) {
      const txt = await buResp.text().catch(() => "");
      return res.status(502).json({ error: "Browser-use request failed", details: txt });
    }

    let checkout = {};
    try {
      const buJson = await buResp.json();
      // Try common shapes:
      //  - direct: { finalPrice, checkoutUrl }
      //  - nested: { result: {...} } or { data: {...} } or text output we need to JSON-parse
      checkout =
        buJson?.result ?? buJson?.data ?? buJson;

      // If the agent returned a string blob, try to extract JSON:
      if (typeof checkout === "string") {
        const m = checkout.match(/\{[\s\S]*\}/);
        checkout = m ? JSON.parse(m[0]) : { raw: checkout };
      }
    } catch {
      checkout = {};
    }

    return res.json({
      query,
      candidates: withUnits,
      best,
      checkout
    });
  } catch (err) {
    console.error(err);
    return res.status(500).json({ error: "Server error" });
  }
});

app.listen(PORT, () => {
  console.log(`DealPilot server running on http://localhost:${PORT}`);
  console.log(`Open http://localhost:${PORT} in your browser.`);
});
EOF

# -------------------------
# Frontend (single input UI)
# -------------------------
mkdir -p public
cat > public/index.html <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <title>DealPilot — Best Unit Price</title>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <style>
    :root { --ink:#0f172a; --muted:#6b7280; --border:#e5e7eb; --accent:#111827; }
    * { box-sizing: border-box; }
    body { margin:0; font-family: system-ui, -apple-system, Segoe UI, Roboto, Arial, "Noto Sans"; background: linear-gradient(#fff,#f6f8fb); color:var(--ink); }
    .wrap { max-width: 720px; margin: 0 auto; padding: 24px; }
    .card { background:#fff; border:1px solid var(--border); border-radius:16px; box-shadow:0 6px 24px rgba(0,0,0,.05); padding:16px; }
    h1 { margin: 0 0 8px; }
    .muted { color: var(--muted); }
    .row { display:flex; gap:12px; align-items:center; }
    .input { flex:1; padding:12px 14px; border:1px solid var(--border); border-radius:12px; font-size:16px; }
    .btn { padding:12px 16px; border-radius:12px; border:1px solid var(--border); background:#fff; cursor:pointer; }
    .btn.primary { background:var(--accent); color:#fff; border-color:var(--accent); }
    .results { margin-top:16px; display:grid; gap:12px; }
    .mono { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace; }
    .pill { display:inline-block; font-size:12px; padding:4px 8px; border:1px solid var(--border); border-radius:999px; }
    .grid { display:grid; grid-template-columns: 1fr 1fr; gap:12px; }
    @media (max-width:700px){ .grid { grid-template-columns: 1fr; } }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <h1>DealPilot</h1>
      <div class="muted">Find best per-unit price, then open checkout and show the final total.</div>
      <div class="row" style="margin-top:12px;">
        <input id="q" class="input" placeholder="Huggies baby diaper size 4" value="Huggies baby diaper size 4"/>
        <button id="go" class="btn primary">Find & Buy</button>
      </div>
      <div id="status" class="muted" style="margin-top:8px;"></div>
      <div id="out" class="results"></div>
    </div>
  </div>

  <script>
    const $ = (id)=>document.getElementById(id);
    const fmt = (n)=>'$'+Number(n ?? 0).toFixed(2);

    $('go').onclick = async () => {
      const query = $('q').value.trim();
      if(!query){ alert('Enter a product'); return; }
      $('status').textContent = 'Working...';
      $('out').innerHTML = '';

      try {
        const r = await fetch('/api/find-and-buy', {
          method:'POST',
          headers: { 'Content-Type':'application/json' },
          body: JSON.stringify({ query })
        });
        const data = await r.json();
        if(!r.ok){ throw new Error(data?.error || 'Request failed'); }

        const cand = document.createElement('div');
        cand.className='card';
        cand.innerHTML = `
          <div class="grid">
            <div>
              <div><strong>Best (per unit):</strong></div>
              <div style="margin-top:6px;">
                <div><span class="pill">${data.best.retailer}</span></div>
                <div class="muted mono" style="margin-top:6px;">pack ${data.best.packSize} — unit ${(data.best.unitPrice).toFixed(3)}</div>
                <div class="muted mono">base ${fmt(data.best.basePrice)}</div>
              </div>
            </div>
            <div>
              <div><strong>Checkout total (agent):</strong></div>
              <div style="margin-top:6px;">
                <div style="font-size:20px; font-weight:700">${fmt(data.checkout.finalPrice)}</div>
                ${data.checkout.checkoutUrl ? `<div style="margin-top:6px;"><a href="${data.checkout.checkoutUrl}" target="_blank">Open checkout</a></div>` : ''}
              </div>
            </div>
          </div>
        `;
        $('out').appendChild(cand);

        const list = document.createElement('div');
        list.className='card';
        list.innerHTML = '<div style="font-weight:600; margin-bottom:8px;">Candidates</div>';
        data.candidates.forEach(c => {
          const row = document.createElement('div');
          row.className='row';
          row.style.justifyContent='space-between';
          row.innerHTML = `
            <div>
              <div><span class="pill">${c.retailer}</span></div>
              <div class="muted mono" style="font-size:12px;margin-top:4px;">pack ${c.packSize} — unit ${(c.unitPrice).toFixed(3)}</div>
            </div>
            <div class="row" style="gap:8px;">
              <div class="mono">${fmt(c.basePrice)}</div>
              <a class="btn" href="${c.productUrl}" target="_blank" rel="noreferrer">View</a>
            </div>
          `;
          list.appendChild(row);
        });
        $('out').appendChild(list);

        $('status').textContent = 'Done.';
      } catch (e) {
        $('status').textContent = 'Error: ' + (e?.message || e);
      }
    };
  </script>
</body>
</html>
EOF

# -------------------------
# README
# -------------------------
cat > README.md <<'EOF'
# DealPilot — Minimal Web App (Frontend + Backend)

A tiny full-stack app that:
1) Lets you type a product (e.g., **“Huggies baby diaper size 4”**),
2) Asks ChatGPT to propose retailer links + pack sizes + prices,
3) Picks the best **per-unit** candidate,
4) Calls **Browser-use Cloud** to navigate to checkout and returns the final checkout price,
5) Shows that price in the UI (and a link to open checkout).

> The agent **stops before** clicking “Place order”.

## Run locally

```bash
cp .env.example .env
# fill OPENAI_API_KEY and BROWSERUSE_API_KEY
npm install
npm run dev
# open http://localhost:3000

