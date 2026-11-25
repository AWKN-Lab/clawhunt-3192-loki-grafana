#!/usr/bin/env node
/**
 * #3192 验收截图：抓 Grafana 的真实界面（AC1 / AC2 / AC4 都要「附截图」）。
 *
 * 用法（在能访问 Grafana 的机器上）：
 *   GRAFANA_URL=http://127.0.0.1:3000 \
 *   GRAFANA_ADMIN_USER=admin GRAFANA_ADMIN_PASSWORD=... \
 *   GRAFANA_USERS_FILE=~/.clawhunt/3192-grafana-users.env \
 *   REQUEST_ID=<某次请求的 request_id> \
 *   node scripts/screenshot.mjs out-dir
 *
 * 产出（out-dir 下）：
 *   ac1-explore-request-id.png   一次请求的全部日志行（同一 request_id 多行）
 *   ac2-explore-masked-phone.png 命中手机号字段的行（已是屏蔽形式）
 *   ac4-dev-user-datasources.png  研发账号在 Grafana 里看不到日志数据源
 *   ac4-admin-datasources.png     对照：运维/管理员能看到 1 个数据源
 *
 * 说明：脚本只读截图，不改任何配置；口令只从环境变量/0600 文件读，不落盘、不进仓。
 */
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';

// playwright 可能只装在全局（ESM 不认 NODE_PATH）⇒ 用 createRequire 按绝对路径加载
const require = createRequire(import.meta.url);
const PW_PATH = process.env.PLAYWRIGHT_PATH || 'playwright';
let chromium;
try {
  ({ chromium } = require(PW_PATH));
} catch (e) {
  ({ chromium } = require('/usr/local/lib/node_modules/playwright'));
}

const GRAFANA_URL = process.env.GRAFANA_URL || 'http://127.0.0.1:3000';
const ADMIN_USER = process.env.GRAFANA_ADMIN_USER || 'admin';
const ADMIN_PASS = process.env.GRAFANA_ADMIN_PASSWORD;
const USERS_FILE = process.env.GRAFANA_USERS_FILE || `${process.env.HOME}/.clawhunt/3192-grafana-users.env`;
const REQUEST_ID = process.env.REQUEST_ID;
const SCRIPT_DIR = path.dirname(new URL(import.meta.url).pathname);
const OUT = path.resolve(process.argv[2] || 'screenshots');
const CHROME = process.env.CHROME_PATH || process.env.CHROMIUM_PATH ||
  '/root/.cache/ms-playwright/chromium-1255/chrome-linux64/chrome';

if (!ADMIN_PASS) { console.error('必须显式提供 GRAFANA_ADMIN_PASSWORD（fail closed）'); process.exit(2); }
if (!REQUEST_ID) { console.error('必须提供 REQUEST_ID（用于按 request_id 查日志）'); process.exit(2); }
fs.mkdirSync(OUT, { recursive: true });

function userCred(login) {
  const raw = fs.readFileSync(USERS_FILE, 'utf8');
  const line = raw.split('\n').find((l) => l.startsWith(`${login}=`));
  if (!line) throw new Error(`凭据文件里没有 ${login}`);
  return line.slice(login.length + 1).trim();
}

const exploreUrl = (query) => {
  const left = {
    datasource: 'Loki',
    queries: [{ query, refId: 'A' }],
    range: { from: 'now-6h', to: 'now' },
  };
  return `${GRAFANA_URL}/explore?left=${encodeURIComponent(JSON.stringify(left))}`;
};

async function login(ctx, page, user, pass) {
  // 用表单 API 登录：会话 cookie 直接落到浏览器 context 里（比点按钮稳，
  // 实测点按钮的写法在 headless 下经常停在登录页，截图拍到的是登录页而不是内容）。
  // Grafana 11 的登录接口要 **JSON 体**（表单编码会返回 400 "bad login data"）
  const resp = await ctx.request.post(`${GRAFANA_URL}/login`, {
    data: { user, password: pass },
    headers: { 'Content-Type': 'application/json' },
    maxRedirects: 0,
  });
  if (!resp.ok() && resp.status() !== 302) {
    throw new Error(`登录失败 ${user}: HTTP ${resp.status()}`);
  }
  await page.goto(`${GRAFANA_URL}/`, { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(1500);
  if (page.url().includes('/login')) throw new Error(`登录后仍在登录页：${user}`);
  console.log(`已登录 ${user}`);
}

// 在 Explore 里把查询跑起来：
//   Grafana 11.3 的 /explore?left=... URL 参数格式已变（直接带 query 会报
//   "Query error: Cannot read properties of undefined (reading 'length')"），
//   ⇒ 改为：打开 Explore → 切 Code 模式 → 输入 LogQL → 点 Run query。
// 仪表盘截图（确定性路径）：面板自带 request_id 文本变量，
// URL 带 ?var-request_id=xxx 即可把「一次请求的全部日志行」渲染出来。
async function shotDashboard(page, dashUid, requestId, file, expectText) {
  const url = `${GRAFANA_URL}/d/${dashUid}/${dashUid}?var-request_id=${encodeURIComponent(requestId)}&refresh=10s`;
  await page.goto(url, { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(6000);
  try {
    await page.waitForSelector(`text=${expectText}`, { timeout: 45000 });
  } catch (e) {
    console.warn(`  ⚠️ 没等到 ${expectText}，仍然截图`);
  }
  await page.waitForTimeout(2000);
  // 视口截图（只拍首屏）：视口外的面板不被 react-grid 渲染，整页截图下半部分是空白
  await page.screenshot({ path: path.join(OUT, file), fullPage: false });
  console.log(`  ✔ ${file}`);
}

// 按面板标题裁剪出「单个面板」的截图（AC2 用：聚焦「近期应用日志」面板，
// 让手机号/身份证/Bearer 的屏蔽形态一眼可见，而不是混在整页里）
async function shotPanel(page, dashUid, requestId, file, panelTitle, expectText) {
  // 面板可能在首屏之外（react-grid 虚拟渲染 ⇒ 视口外的面板不在 DOM 里），
  // ⇒ 用 Grafana 的 viewPanel 参数单独打开该面板，路径确定、无需滚动。
  const dashFile = path.join(SCRIPT_DIR, '..', 'grafana', 'dashboards', `${dashUid}.json`);
  const dash = JSON.parse(fs.readFileSync(dashFile, 'utf-8'));
  const panel = (dash.panels || []).find((x) => (x.title || '').includes(panelTitle));
  if (!panel) {
    console.warn(`  ⚠️ 仪表盘 ${dashUid} 里找不到面板「${panelTitle}」，整页截图`);
    await page.goto(`${GRAFANA_URL}/d/${dashUid}/${dashUid}?var-request_id=${encodeURIComponent(requestId)}`,
      { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(6000);
    await page.screenshot({ path: path.join(OUT, file), fullPage: true });
    return;
  }
  const url = `${GRAFANA_URL}/d/${dashUid}/${dashUid}?viewPanel=${panel.id}&var-request_id=${encodeURIComponent(requestId)}&refresh=10s`;
  await page.goto(url, { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(6000);
  try {
    await page.waitForSelector(`text=${expectText}`, { timeout: 45000 });
  } catch (e) {
    console.warn(`  ⚠️ 没等到 ${expectText}，仍然截图`);
  }
  await page.waitForTimeout(2500);
  await page.screenshot({ path: path.join(OUT, file), fullPage: false });
  console.log(`  ✔ ${file}（单独打开面板「${panelTitle}」id=${panel.id}）`);
}

async function shotExplore(page, query, file, expectText) {
  await page.goto(`${GRAFANA_URL}/explore`, { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(3000);
  const codeBtn = page.locator('button:has-text("Code"), [aria-label="Code"]').first();
  if (await codeBtn.count()) { await codeBtn.click().catch(() => {}); await page.waitForTimeout(1500); }
  const editor = page.locator('.monaco-editor textarea, textarea.inputarea, textarea').first();
  await editor.click({ timeout: 20000 });
  await page.keyboard.press('Control+A');
  await page.keyboard.press('Delete');
  await page.keyboard.type(query, { delay: 8 });
  await page.waitForTimeout(800);
  const runBtn = page.locator('button[aria-label="Run query"], button:has-text("Run query")').first();
  if (await runBtn.count()) await runBtn.click().catch(() => {});
  await page.keyboard.press('Control+Enter');
  try {
    await page.waitForSelector(`text=${expectText}`, { timeout: 45000 });
  } catch (e) {
    console.warn(`  ⚠️ 没等到 ${expectText}，仍然截图（可能查询无结果）`);
  }
  await page.waitForTimeout(1500);
  await page.screenshot({ path: path.join(OUT, file), fullPage: false });
  console.log(`  ✔ ${file}`);
}

const browser = await chromium.launch({ executablePath: CHROME, args: ['--no-sandbox'] });

// ── admin：AC1（按 request_id 查全部日志行）+ AC2（屏蔽后的手机号）──────────
{
  const ctx = await browser.newContext({ viewport: { width: 1600, height: 900 }, deviceScaleFactor: 1 });
  const page = await ctx.newPage();
  await login(ctx, page, ADMIN_USER, ADMIN_PASS);
  // AC1：单独打开「按 request_id 追踪」面板（视口外的面板不会被 react-grid 渲染，
  //       整页截图会是空白 ⇒ 证据必须落在 viewPanel 上）
  await shotPanel(page, 'loki-log-panels', REQUEST_ID, 'ac1-request-id-all-lines.png',
    '按 request_id 追踪：一次请求的全部日志行（AC1）', REQUEST_ID);
  // 面板三件套（工单要求：错误日志趋势 / 按 service 统计 error 数 / route 点击跳转）
  await shotDashboard(page, 'loki-log-panels', REQUEST_ID, 'ac1-dashboard-overview.png', '错误日志趋势');
  await shotPanel(page, 'loki-log-panels', REQUEST_ID, 'ac2-masked-phone.png',
    '脱敏样本：手机号 / 身份证 / Bearer（AC2）', '138****1111');
  // 数据源列表（对照：admin 能看到 Loki）
  await page.goto(`${GRAFANA_URL}/connections/datasources`, { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(3000);
  await page.screenshot({ path: path.join(OUT, 'ac4-admin-datasources.png') });
  console.log('  ✔ ac4-admin-datasources.png');
  await ctx.close();
}

// ── dev-user：AC4（看不到日志数据源）──────────────────────────────────────
{
  const ctx = await browser.newContext({ viewport: { width: 1600, height: 900 }, deviceScaleFactor: 1 });
  const page = await ctx.newPage();
  await login(ctx, page, 'dev-user', userCred('dev-user'));
  // 数据源页：无权限 ⇒ 被弹回首页，导航里也没有 Connections / Explore
  await page.goto(`${GRAFANA_URL}/connections/datasources`, { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(4000);
  await page.screenshot({ path: path.join(OUT, 'ac4-dev-user-no-datasource.png') });
  console.log('  ✔ ac4-dev-user-no-datasource.png');
  // API 级证据：dev-user 调 GET /api/datasources ⇒ 403（UI 上被弹回首页只是表象）
  const apiRes = await page.evaluate(async () => {
    const out = {};
    for (const q of ['/api/datasources', '/api/datasources/uid/loki', '/api/dashboards/home']) {
      try {
        const r = await fetch(q, { credentials: 'include' });
        out[q] = { status: r.status, body: (await r.text()).slice(0, 300) };
      } catch (e) { out[q] = { error: String(e) }; }
    }
    return out;
  });
  const evidenceDir = path.join(OUT, '..', 'evidence');
  fs.mkdirSync(evidenceDir, { recursive: true });
  fs.writeFileSync(path.join(evidenceDir, 'ac4-dev-user-api.json'),
    JSON.stringify({ user: 'dev-user', org_role: 'None', captured_at: new Date().toISOString(), results: apiRes }, null, 2));
  console.log('  ✔ evidence/ac4-dev-user-api.json（dev-user 调数据源 API 的真实状态码）');
  await ctx.close();
}

await browser.close();
console.log(`截图输出目录：${OUT}`);
