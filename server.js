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
