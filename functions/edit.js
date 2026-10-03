// www.diamondbarevergreen.com/edit - launcher for the on-demand editor.
// A Cloudflare Pages Function deployed with the site itself, so the customer
// never leaves their own domain. No storage binding needed: the running
// session's URL is read from the "session" branch of this (public) repo, where
// tools/dbec-edit-session.sh publishes it; a booting run is detected from the
// public Actions API. No start password: opening the page starts a session
// automatically (via an auto-submitted POST, so bots/link previews doing a
// plain GET never trigger one). The editor itself has its own login.
// One Pages project secret is needed (Settings -> Variables and secrets):
// GH_TOKEN - fine-grained PAT, Actions read/write on this repo only.

const REPO = "ryx168/dbec_site";
const WORKFLOW = "dbec-edit-session.yml";
const SESSION_MAX_AGE_MS = 6 * 3600 * 1000;
const JUST_STARTED_MS = 120 * 1000;   // after a dispatch, don't auto-submit again for this long
const GH_HEADERS = { "accept": "application/vnd.github+json", "user-agent": "dbec-edit-launcher" };

function page(body, refresh) {
  return new Response(`<!doctype html><html lang="zh-Hant"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex">
<title>鑽石吧長青會 網站編輯器</title>${refresh ? `<meta http-equiv="refresh" content="${refresh}">` : ""}
<style>
body{font-family:system-ui,"PingFang TC","Microsoft JhengHei",sans-serif;background:#f4f6f8;margin:0;display:flex;min-height:100vh;align-items:center;justify-content:center;color:#222}
.card{background:#fff;border-radius:12px;box-shadow:0 2px 12px rgba(0,0,0,.08);padding:36px 40px;max-width:460px;width:90%}
h1{font-size:20px;margin:0 0 8px}p{line-height:1.6;color:#555}
button{font-size:16px;padding:12px 14px;border-radius:8px;border:0;width:100%;background:#1a73e8;color:#fff;cursor:pointer;margin-top:12px;font-weight:600}
a.go{display:block;text-align:center;background:#188038;color:#fff;text-decoration:none;padding:14px;border-radius:8px;font-weight:600;font-size:17px}
.muted{font-size:13px;color:#888}.err{color:#c5221f;font-weight:600}
.spin{width:28px;height:28px;border:3px solid #ddd;border-top-color:#1a73e8;border-radius:50%;animation:s 1s linear infinite;margin:12px auto}@keyframes s{to{transform:rotate(360deg)}}
</style></head><body><div class="card">${body}</div></body></html>`,
    { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
}

const STARTING = `<h1>編輯器啟動中…</h1><div class="spin"></div><p>通常需要約 1 分鐘，此頁面會自動更新，請稍候。</p>`;

// Newest run of the workflow, any status - GitHub reports brief "pending"/
// "requested" states that a status-filtered query would miss.
async function newestRun() {
  const r = await fetch(`https://api.github.com/repos/${REPO}/actions/workflows/${WORKFLOW}/runs?per_page=1`,
    { headers: GH_HEADERS, cf: { cacheTtl: 0 } }).catch(() => null);
  if (!r || !r.ok) return null;
  const j = await r.json().catch(() => ({}));
  return (j.workflow_runs || [])[0] || null;
}

async function sessionState() {
  const run = await newestRun();
  const runActive = !!run && run.status !== "completed";
  // A published session URL only counts while its run is still alive -
  // a cancelled/crashed runner never gets to delete the branch.
  if (runActive) {
    const raw = await fetch(`https://raw.githubusercontent.com/${REPO}/session/edit-session.json?t=${Date.now()}`,
      { headers: GH_HEADERS, cf: { cacheTtl: 0, cacheEverything: false } }).catch(() => null);
    if (raw && raw.ok) {
      const s = await raw.json().catch(() => null);
      if (s && /^https:\/\/[a-z0-9-]+\.trycloudflare\.com$/.test(s.url || "") &&
          Date.now() - Date.parse(s.since || 0) < SESSION_MAX_AGE_MS) {
        return { state: "running", url: s.url, sftpHost: s.sftp_host || "", sftpPort: s.sftp_port || "" };
      }
    }
    return { state: "starting" };
  }
  return { state: "idle" };
}

function justStarted(url) {
  const s = Number(new URL(url).searchParams.get("s") || 0);
  return s > 0 && Date.now() - s < JUST_STARTED_MS;
}

export async function onRequestGet({ request }) {
  const cur = await sessionState();
  if (cur.state === "running") {
    const sftp = cur.sftpPort
      ? `<p class="muted" style="margin-top:16px">也可用 SFTP 軟體（如 FileZilla）連線，適合大量檔案：<br>
主機 <b>${cur.sftpHost}</b>　連接埠 <b>${cur.sftpPort}</b>　帳號 <b>conan</b><br>
（連線類型選 <b>SFTP</b>；每次開啟編輯器主機與連接埠都會不同，請以此頁為準。）</p>`
      : "";
    return page(`<h1>編輯器已開啟</h1><p>請點下方按鈕進入。登入帳號 <b>conan</b>，密碼為您收到的編輯器密碼。</p>
<a class="go" href="${cur.url}" target="_blank" rel="noopener">進入編輯器</a>
<p class="muted">閒置 15 分鐘後編輯器會自動關閉；修改會自動儲存，並在約 1 分鐘內更新到網站。</p>${sftp}`);
  }
  if (cur.state === "starting" || justStarted(request.url)) {
    const s = new URL(request.url).searchParams.get("s");
    return page(STARTING, `6; url=/edit${s ? `?s=${encodeURIComponent(s)}` : ""}`);
  }
  // idle: start automatically - the browser submits this form on load; a plain
  // GET (crawlers, link previews) stops here and starts nothing.
  return page(`<h1>鑽石吧長青會 網站編輯器</h1><div class="spin"></div><p>正在啟動編輯器…</p>
<form method="post"><noscript><button type="submit">開始編輯</button></noscript></form>
<script>document.forms[0].submit()</script>`);
}

export async function onRequestPost({ request, env }) {
  const cur = await sessionState();
  if (cur.state !== "idle") return Response.redirect(new URL("/edit", request.url), 303);
  if (!env.GH_TOKEN) {
    return page(`<h1>尚未完成設定</h1><p class="err">啟動器還沒有 GitHub 權杖（Pages 專案的 GH_TOKEN 尚未設定），請聯絡管理員。</p>`);
  }
  const r = await fetch(`https://api.github.com/repos/${REPO}/actions/workflows/${WORKFLOW}/dispatches`, {
    method: "POST",
    headers: { ...GH_HEADERS, "authorization": `Bearer ${env.GH_TOKEN}`, "content-type": "application/json" },
    body: JSON.stringify({ ref: "main", inputs: { idle_minutes: "15" } }),
  });
  if (r.status !== 204) {
    const t = (await r.text()).slice(0, 300).replace(/</g, "&lt;");
    return page(`<h1>啟動失敗</h1><p class="err">GitHub 回應 ${r.status}</p><p class="muted">${t}</p><p><a href="/edit">重試</a></p>`);
  }
  // Carry a timestamp so the follow-up GETs never show the auto-submit page
  // during the few seconds before the API lists the new run.
  return page(STARTING, `6; url=/edit?s=${Date.now()}`);
}
