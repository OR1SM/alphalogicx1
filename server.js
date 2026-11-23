/* Alpha LogicX — خادم الموقع على Render
   - يقدّم index.html مضغوطاً (gzip) مع تخزين مؤقت
   - /api/yt/search و /api/yt/videos : بحث يوتيوب من جهة السيرفر (لا مشاكل CORS ولا خوادم عامة ميتة)
       • إذا وُجد YOUTUBE_API_KEY  → YouTube Data API v3 الرسمي
       • بدونه                     → قراءة صفحة نتائج يوتيوب مباشرة وتحويلها لنفس الشكل
   بدون أي مكتبات خارجية: Node 18+ فقط */
"use strict";
const http = require("http"), fs = require("fs"), path = require("path"), zlib = require("zlib"), crypto = require("crypto");

const PORT = process.env.PORT || 10000;
const KEY = (process.env.YOUTUBE_API_KEY || "").trim();
const GEMINI = (process.env.GEMINI_API_KEY || "").trim();
/* يبحث عن index.html في أكثر من مكان حتى لو تغيّر ترتيب المجلدات في المستودع */
const ROOT = [path.join(__dirname, "public"), __dirname, path.join(__dirname, "deploy", "public"), path.join(process.cwd(), "public")]
  .find(d => fs.existsSync(path.join(d, "index.html"))) || path.join(__dirname, "public");
const API = "https://www.googleapis.com/youtube/v3";

/* ---------- الملفات الثابتة: تُقرأ وتُضغط مرة واحدة عند التشغيل ---------- */
const TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8", ".json": "application/json", ".png": "image/png", ".svg": "image/svg+xml", ".ico": "image/x-icon", ".webmanifest": "application/manifest+json"};
const files = new Map();
function load(rel) {
  const abs = path.join(ROOT, rel);
  if (!abs.startsWith(ROOT) || !fs.existsSync(abs) || !fs.statSync(abs).isFile()) return null;
  if (files.has(rel)) return files.get(rel);
  const raw = fs.readFileSync(abs), type = TYPES[path.extname(rel)] || "application/octet-stream";
  const f = {raw, type, etag: '"' + crypto.createHash("sha1").update(raw).digest("hex").slice(0, 16) + '"', gz: /text|json|svg|javascript/.test(type) ? zlib.gzipSync(raw, {level: 9}) : null};
  files.set(rel, f); return f;
}
console.time("index ready");
if (load("index.html")) console.log("serving", path.join(ROOT, "index.html"), (files.get("index.html").raw.length / 1048576).toFixed(1) + " MB");
else console.error("!! index.html NOT FOUND. Looked in: public/, ./, deploy/public/ — make sure the 76 MB index.html is in the GitHub repo.");
console.timeEnd("index ready");

/* ---------- يوتيوب ---------- */
const cache = new Map(); /* استعلام → نتيجة (ساعة) */
const meta = new Map();  /* معرّف فيديو → مدة ومشاهدات (لـ /videos بدون مفتاح) */
function remember(k, v) {cache.set(k, {t: Date.now(), v}); if (cache.size > 500) cache.delete(cache.keys().next().value);}
function cached(k) {const c = cache.get(k); return c && Date.now() - c.t < 3600e3 ? c.v : null;}

async function getJSON(url) {
  const r = await fetch(url, {signal: AbortSignal.timeout(9000)});
  const j = await r.json().catch(() => ({}));
  if (!r.ok) {const e = new Error((j.error && j.error.message) || "HTTP " + r.status); e.status = r.status; e.body = j; throw e;}
  return j;
}
/* بدون مفتاح: صفحة نتائج يوتيوب تحتوي ytInitialData (JSON) */
function walk(o, out) {
  if (!o || typeof o !== "object") return;
  if (o.videoRenderer && o.videoRenderer.videoId) out.push(o.videoRenderer);
  else for (const k in o) walk(o[k], out);
}
const txt = x => x ? (x.simpleText || (x.runs || []).map(r => r.text).join("")) : "";
function isoFromClock(s) {const p = String(s || "").split(":").map(Number).reverse(); if (!p[0] && p[0] !== 0) return ""; return "PT" + (p[2] ? p[2] + "H" : "") + (p[1] ? p[1] + "M" : "") + (p[0] || 0) + "S";}
function parseResults(html) {
  const m = html.match(/var ytInitialData\s*=\s*(\{[\s\S]*?\});\s*<\/script>/) || html.match(/ytInitialData"\]\s*=\s*(\{[\s\S]*?\});/);
  if (!m) throw Object.assign(new Error("no ytInitialData"), {status: 502});
  const list = []; walk(JSON.parse(m[1]), list);
  return list.map(v => {
    const views = +(txt(v.viewCountText).replace(/[^\d]/g, "")) || 0;
    meta.set(v.videoId, {duration: isoFromClock(txt(v.lengthText)), viewCount: String(views)});
    return {kind: "youtube#searchResult", id: {kind: "youtube#video", videoId: v.videoId}, snippet: {title: txt(v.title), channelTitle: txt(v.ownerText || v.longBylineText), publishedAt: null, description: txt(v.detailedMetadataSnippets && v.detailedMetadataSnippets[0] && v.detailedMetadataSnippets[0].snippetText)}};
  });
}
async function scrapeSearch(q, lang) {
  const url = "https://www.youtube.com/results?search_query=" + encodeURIComponent(q) + "&sp=EgIQAQ%253D%253D&hl=" + lang + "&gl=JO";
  const r = await fetch(url, {signal: AbortSignal.timeout(9000), headers: {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36", "Accept-Language": lang + ",en;q=0.8", "Cookie": "CONSENT=YES+1; SOCS=CAI"}});
  if (!r.ok) throw Object.assign(new Error("youtube HTTP " + r.status), {status: 502});
  return {kind: "youtube#searchListResponse", items: parseResults(await r.text()).slice(0, 20), nextPageToken: null, source: "scrape"};
}

async function yt(route, qs) {
  if (route === "search") {
    const q = (qs.get("q") || "").slice(0, 200).trim(); if (!q) throw Object.assign(new Error("missing q"), {status: 400});
    const lang = qs.get("relevanceLanguage") === "en" ? "en" : "ar", page = qs.get("pageToken") || "";
    const ck = "s|" + lang + "|" + q + "|" + page + "|" + (KEY ? "k" : "x"); const hit = cached(ck); if (hit) return hit;
    let out;
    if (KEY) {
      const p = new URLSearchParams({part: "snippet", type: "video", videoEmbeddable: "true", maxResults: "20", safeSearch: "strict", relevanceLanguage: lang, q, key: KEY}); if (page) p.set("pageToken", page);
      try {out = await getJSON(API + "/search?" + p);} catch (e) {if (e.status === 403 || e.status === 429) out = await scrapeSearch(q, lang); else throw e;} /* نفدت الحصة → القراءة المباشرة */
    } else {
      if (page) return {items: [], nextPageToken: null};
      out = await scrapeSearch(q, lang);
    }
    remember(ck, out); return out;
  }
  if (route === "videos") {
    const ids = (qs.get("id") || "").split(",").filter(x => /^[\w-]{11}$/.test(x)).slice(0, 50); if (!ids.length) return {items: []};
    if (KEY) {try {return await getJSON(API + "/videos?" + new URLSearchParams({part: "contentDetails,statistics", id: ids.join(","), key: KEY}));} catch (e) { }}
    return {items: ids.filter(id => meta.has(id)).map(id => ({id, contentDetails: {duration: meta.get(id).duration}, statistics: {viewCount: meta.get(id).viewCount}}))};
  }
  throw Object.assign(new Error("not found"), {status: 404});
}

/* ---------- Gemini: الموقع يرسل كل طلبات generativelanguage.googleapis.com إلى /api/gemini/v1beta/...
   والمفتاح يُضاف هنا من GEMINI_API_KEY فلا يصل للمتصفح أبداً ---------- */
const GEM_PATH = /^\/api\/gemini\/(v1beta|v1)\/(models(?:\/[\w.-]+:(?:generateContent|countTokens))?)$/;
const hits = new Map(); /* حدّ بسيط: 40 طلب/دقيقة لكل IP */
function limited(ip) {const now = Date.now(), h = (hits.get(ip) || []).filter(t => now - t < 60e3); h.push(now); hits.set(ip, h); if (hits.size > 5000) hits.clear(); return h.length > (ip.startsWith("tts:") ? 60 : 40);}
function readBody(req, max) {
  return new Promise((ok, bad) => {let n = 0; const parts = []; req.on("data", c => {n += c.length; if (n > max) {bad(Object.assign(new Error("body too large"), {status: 413})); req.destroy();} else parts.push(c);}); req.on("end", () => ok(Buffer.concat(parts))); req.on("error", bad);});
}
async function gemini(req, res, m, u) {
  const J = {"Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"};
  if (!GEMINI) return send(res, 503, JSON.stringify({error: {message: "GEMINI_API_KEY غير مضبوط على السيرفر (Render → Environment)", status: "NO_KEY"}}), J);
  const ip = String(req.headers["x-forwarded-for"] || req.socket.remoteAddress || "").split(",")[0].trim();
  if (limited(ip)) return send(res, 429, JSON.stringify({error: {message: "طلبات كثيرة، انتظر دقيقة", status: "RESOURCE_EXHAUSTED"}}), J);
  const isPost = req.method === "POST";
  if (isPost !== /:/.test(m[2])) return send(res, 405, JSON.stringify({error: {message: "method not allowed"}}), J);
  try {
    const body = isPost ? await readBody(req, 2 * 1048576) : undefined;
    const q = new URLSearchParams(); if (u.searchParams.get("pageSize")) q.set("pageSize", u.searchParams.get("pageSize")); if (u.searchParams.get("pageToken")) q.set("pageToken", u.searchParams.get("pageToken"));
    const r = await fetch("https://generativelanguage.googleapis.com/" + m[1] + "/" + m[2] + (q.toString() ? "?" + q : ""), {method: req.method, body, headers: {"Content-Type": "application/json", "x-goog-api-key": GEMINI}, signal: AbortSignal.timeout(60000)});
    const out = Buffer.from(await r.arrayBuffer());
    if (!r.ok) console.warn("gemini", r.status, m[2], out.toString().slice(0, 200));
    send(res, r.status, out, J);
  } catch (e) {console.warn("gemini", e.message); send(res, e.status || 502, JSON.stringify({error: {message: "تعذّر الوصول إلى Gemini: " + e.message}}), J);}
}

/* ---------- قراءة النص بصوت Google (Gemini TTS) ----------
   POST /api/tts {text, lang} → audio/wav. يُخزَّن الصوت مؤقتاً فلا يُطلب النص نفسه مرتين. */
const TTS_MODELS = ["gemini-3.8-flash-tts", "gemini-3.8-flash-lite-tts", "gemini-3.1-flash-tts-preview", "gemini-2.5-flash-preview-tts"];
const ttsCache = new Map();
function wavFromPcm(pcm, rate) {
  const h = Buffer.alloc(44); h.write("RIFF", 0); h.writeUInt32LE(36 + pcm.length, 4); h.write("WAVE", 8); h.write("fmt ", 12); h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22);
  h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34); h.write("data", 36); h.writeUInt32LE(pcm.length, 40); return Buffer.concat([h, pcm]);
}
async function tts(req, res) {
  const J = {"Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"};
  if (!GEMINI) return send(res, 503, JSON.stringify({error: {message: "GEMINI_API_KEY غير مضبوط"}}), J);
  const ip = String(req.headers["x-forwarded-for"] || req.socket.remoteAddress || "").split(",")[0].trim();
  if (limited("tts:" + ip)) return send(res, 429, JSON.stringify({error: {message: "طلبات كثيرة"}}), J);
  let body; try {body = JSON.parse((await readBody(req, 20000)).toString() || "{}");} catch (e) {return send(res, 400, JSON.stringify({error: {message: "bad json"}}), J);}
  const text = String(body.text || "").replace(/\s+/g, " ").trim().slice(0, 900), voice = /^[A-Za-z]{2,20}$/.test(body.voice || "") ? body.voice : "Kore";
  if (!text) return send(res, 400, JSON.stringify({error: {message: "no text"}}), J);
  const key = voice + "|" + text, hit = ttsCache.get(key);
  const A = {"Content-Type": "audio/wav", "Cache-Control": "public, max-age=86400"};
  if (hit) {ttsCache.delete(key); ttsCache.set(key, hit); return send(res, 200, hit, A);}
  let last = "";
  for (const m of TTS_MODELS) {
    try {
      const r = await fetch("https://generativelanguage.googleapis.com/v1beta/models/" + m + ":generateContent", {method: "POST", headers: {"Content-Type": "application/json", "x-goog-api-key": GEMINI}, signal: AbortSignal.timeout(30000),
        body: JSON.stringify({contents: [{parts: [{text}]}], generationConfig: {responseModalities: ["AUDIO"], speechConfig: {voiceConfig: {prebuiltVoiceConfig: {voiceName: voice}}}}})});
      const j = await r.json().catch(() => ({}));
      const p = j.candidates && j.candidates[0] && j.candidates[0].content && (j.candidates[0].content.parts || []).find(x => x.inlineData);
      if (!r.ok || !p) {last = m + ": " + ((j.error && j.error.message) || r.status); continue;}
      const raw = Buffer.from(p.inlineData.data, "base64"), mt = String(p.inlineData.mimeType || "");
      const wav = /wav/i.test(mt) || raw.slice(0, 4).toString() === "RIFF" ? raw : wavFromPcm(raw, +((mt.match(/rate=(\d+)/) || [])[1] || 24000));
      ttsCache.set(key, wav); if (ttsCache.size > 120) ttsCache.delete(ttsCache.keys().next().value);
      return send(res, 200, wav, A);
    } catch (e) {last = m + ": " + e.message;}
  }
  console.warn("tts", last); send(res, 502, JSON.stringify({error: {message: "تعذّر توليد الصوت: " + last}}), J);
}

/* ---------- الخادم ---------- */
function send(res, code, body, headers) {res.writeHead(code, Object.assign({"X-Content-Type-Options": "nosniff"}, headers)); res.end(body);}
http.createServer(async (req, res) => {
  const u = new URL(req.url, "http://x");
  if (u.pathname === "/healthz") return send(res, 200, "ok", {"Content-Type": "text/plain"});
  const gm = u.pathname.match(GEM_PATH); if (gm) return gemini(req, res, gm, u);
  if (u.pathname === "/api/tts" && req.method === "POST") return tts(req, res);
  const m = u.pathname.match(/^\/api\/yt\/(search|videos)$/);
  if (m) {
    try {const j = await yt(m[1], u.searchParams); send(res, 200, JSON.stringify(j), {"Content-Type": "application/json; charset=utf-8", "Cache-Control": "public, max-age=600", "Access-Control-Allow-Origin": "*"});}
    catch (e) {console.warn("yt", m[1], e.message); send(res, e.status && e.status < 500 ? e.status : 502, JSON.stringify({error: {message: e.message}}), {"Content-Type": "application/json", "Access-Control-Allow-Origin": "*"});}
    return;
  }
  if (u.pathname.startsWith("/api/")) return send(res, 404, JSON.stringify({error: {message: "unknown api"}}), {"Content-Type": "application/json"});
  if (req.method !== "GET" && req.method !== "HEAD") return send(res, 405, "");
  let rel = decodeURIComponent(u.pathname).replace(/^\/+/, "") || "index.html";
  if (rel === "server.js" || rel === "package.json" || rel.startsWith(".")) rel = "index.html"; /* لا نكشف ملفات الخادم */
  const f = load(rel) || load("index.html"); /* أي مسار آخر يعيد الموقع نفسه */
  if (!f) return send(res, 503, "<h1 dir=rtl>Alpha LogicX: ملف index.html غير موجود في المستودع</h1>", {"Content-Type": "text/html; charset=utf-8"});
  if (req.headers["if-none-match"] === f.etag) return send(res, 304, "", {ETag: f.etag});
  const gz = f.gz && /\bgzip\b/.test(req.headers["accept-encoding"] || "");
  const h = {"Content-Type": f.type, ETag: f.etag, "Cache-Control": rel === "index.html" ? "no-cache" : "public, max-age=86400", Vary: "Accept-Encoding"};
  if (gz) h["Content-Encoding"] = "gzip";
  const body = gz ? f.gz : f.raw; h["Content-Length"] = body.length;
  send(res, 200, req.method === "HEAD" ? "" : body, h);
}).listen(PORT, () => console.log("Alpha LogicX on :" + PORT + (KEY ? " · YouTube key ✓" : " · no YouTube key (direct search)") + (GEMINI ? " · Gemini key ✓" : " · NO GEMINI_API_KEY → AI assistant off")));
