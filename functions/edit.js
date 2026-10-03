// www.diamondbarevergreen.com/edit - launcher for the on-demand editor.
// A Cloudflare Pages Function deployed with the site itself, so the customer
// never leaves their own domain. No storage binding needed: the running
// session's URL is read from the "session" branch of this (public) repo, where
// tools/dbec-edit-session.sh publishes it; "starting" is detected from the
// public Actions API. Only starting a session needs secrets, set on the Pages
// project (Settings -> Variables and secrets): GH_TOKEN (fine-grained PAT,
// Actions read/write on this repo only) and LAUNCH_PASS (the start password).

const REPO = "ryx168/dbec_site";
const WORKFLOW = "dbec-edit-session.yml";
const SESSION_MAX_AGE_MS = 6 * 3600 * 1000;
const GH_HEADERS = { "accept": "application/vnd.github+json", "user-agent": "dbec-edit-launcher" };

function page(body, refresh) {
  return new Response(`<!doctype html><html lang="zh-Hant"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex">
<title>鑽石吧長青會 網站編輯器</title>${refresh ? `<meta http-equiv="refresh" content="${refresh}">` : ""}
<style>
body{font-family:system-ui,"PingFang TC","Microsoft JhengHei",sans-serif;background:#f4f6f8;margin:0;display:flex;min-height:100vh;align-items:center;justify-content:center;color:#222}
.card{background:#fff;border-radius:12px;box-shadow:0 2px 12px rgba(0,0,0,.08);padding:36px 40px;max-width:460px;width:90%}
h1{font-size:20px;margin:0 0 8px}p{line-height:1.6;color:#555}
input,button{font-size:16px;padding:12px 14px;border-radius:8px;border:1px solid #ccc;width:100%;box-sizing:border-box}
button{background:#1a73e8;color:#fff;border:0;cursor:pointer;margin-top:12px;font-weight:600}button:hover{background:#1557b0}
a.go{display:block;text-align:center;background:#188038;color:#fff;text-decoration:none;padding:14px;border-radius:8px;font-weight:600;font-size:17px}
.muted{font-size:13px;color:#888}.err{color:#c5221f;font-weight:600}
.spin{width:28px;height:28px;border:3px solid #ddd;border-top-color:#1a73e8;border-radius:50%;animation:s 1s linear infinite;margin:12px auto}@keyframes s{to{transform:rotate(360deg)}}
</style></head><body><div class="card">${body}</div></body></html>`,
    { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
}

async function sessionState() {
  // 1) a published session URL on the "session" branch?
  const raw = await fetch(`https://raw.githubusercontent.com/${REPO}/session/edit-session.json?t=${Date.now()}`,
    { headers: GH_HEADERS, cf: { cacheTtl: 0, cacheEverything: false } }).catch(() => null);
  if (raw && raw.ok) {
    const s = await raw.json().catch(() => null);
    if (s && /^https:\/\/[a-z0-9-]+\.trycloudflare\.com$/.test(s.url || "") &&
        Date.now() - Date.parse(s.since || 0) < SESSION_MAX_AGE_MS) {
      return { state: "running", url: s.url };
    }
  }
  // 2) a run already in progress (booting) ?
  for (const status of ["in_progress", "queued"]) {
    const r = await fetch(`https://api.github.com/repos/${REPO}/actions/workflows/${WORKFLOW}/runs?status=${status}&per_page=1`,
      { headers: GH_HEADERS, cf: { cacheTtl: 0 } }).catch(() => null);
    if (r && r.ok) {
      const j = await r.json().catch(() => ({}));
      if ((j.total_count || 0) > 0) return { state: "starting" };
    }
  }
  return { state: "idle" };
}

function safeEqual(a, b) {
  const enc = new TextEncoder();
  const x = enc.encode(a || ""), y = enc.encode(b || "");
  if (x.length !== y.length) return false;
  let r = 0; for (let i = 0; i < x.length; i++) r |= x[i] ^ y[i];
  return r === 0;
}

export async function onRequestGet() {
  const cur = await sessionState();
  if (cur.state === "running") {
    return page(`<h1>編輯器已開啟</h1><p>請點下方按鈕進入。登入帳號 <b>conan</b>，密碼為您收到的編輯器密碼。</p>
<a class="go" href="${cur.url}" target="_blank" rel="noopener">進入編輯器</a>
<p class="muted">閒置 15 分鐘後編輯器會自動關閉；修改會自動儲存，並在約 1 分鐘內更新到網站。</p>`);
  }
  if (cur.state === "starting") {
    return page(`<h1>編輯器啟動中…</h1><div class="spin"></div><p>通常需要約 1 分鐘，此頁面會自動更新，請稍候。</p>`, 6);
  }
  return page(`<h1>鑽石吧長青會 網站編輯器</h1><p>輸入啟動密碼後按「開始編輯」，約 1 分鐘後即可進入編輯器。</p>
<form method="post"><input type="password" name="password" placeholder="啟動密碼" autofocus required><button type="submit">開始編輯</button></form>
<p class="muted">編輯器裡的修改會自動儲存，並自動更新到 www.diamondbarevergreen.com。</p>`);
}

export async function onRequestPost({ request, env }) {
  const form = await request.formData();
  if (!env.LAUNCH_PASS || !safeEqual(form.get("password"), env.LAUNCH_PASS)) {
    return page(`<h1>密碼錯誤</h1><p class="err">請重新輸入。</p><p><a href="/edit">返回</a></p>`);
  }
  const cur = await sessionState();
  if (cur.state !== "idle") return Response.redirect(new URL("/edit", request.url), 303);
  if (!env.GH_TOKEN) {
    return page(`<h1>尚未完成設定</h1><p class="err">啟動器還沒有 GitHub 權杖（GH_TOKEN），請聯絡管理員。</p>`);
  }
  const r = await fetch(`https://api.github.com/repos/${REPO}/actions/workflows/${WORKFLOW}/dispatches`, {
    method: "POST",
    headers: { ...GH_HEADERS, "authorization": `Bearer ${env.GH_TOKEN}`, "content-type": "application/json" },
    body: JSON.stringify({ ref: "main", inputs: { idle_minutes: "15" } }),
  });
  if (r.status !== 204) {
    const t = (await r.text()).slice(0, 300).replace(/</g, "&lt;");
    return page(`<h1>啟動失敗</h1><p class="err">GitHub 回應 ${r.status}</p><p class="muted">${t}</p><p><a href="/edit">返回</a></p>`);
  }
  return page(`<h1>編輯器啟動中…</h1><div class="spin"></div><p>通常需要約 1 分鐘，此頁面會自動更新，請稍候。</p>`, 6);
}
