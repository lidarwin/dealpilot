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

