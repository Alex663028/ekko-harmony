/**
 * 服务端端点契约守卫。
 *
 * 背景：这次「登录后显示 Not Found」是因为代码里给
 * `/api/coding-agents` 多写了 `studio/` 前缀，服务端 404。
 * 而 `/api/coding-agents` 虽然 200，返回的却是 `{tools:[...]}`
 * （编码 CLI 工具）而不是代码预期的 `{agents:[...]}` ——
 * 解析出 undefined，Agent 列表永远空，**但不报错**。
 *
 * 这两类问题编译器和单测都抓不到，只有真打服务端才能发现。
 * 所以把「代码里用到的每个路径 + 期望的响应形状」固化成本守卫，
 * 以后改路径时忘了同步，这里就会红。
 *
 * 用法：
 *   node run_endpoint_guard.mjs            # 只做静态检查（不连服务端）
 *   node run_endpoint_guard.mjs --live     # 顺便真打一遍服务端
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * 源码根目录，**按本文件位置解析**。
 *
 * 🔴 不能写死绝对路径（2026-10-07 交付时发现）
 *   原本是写死 '<项目根>/entry/src/main/ets'，项目复制到别的目录后
 *   守卫会静默扫不到文件 → 「通过」但什么都没检查。
 *   比测试全绿更危险：绿灯是假的。
 */
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SRC_ROOT = path.join(__dirname, '..', 'entry', 'src', 'main', 'ets');

const SRC = SRC_ROOT;
const BASE = process.env.EKKO_BASE || 'http://127.0.0.1:8748';
const TOKEN = process.env.EKKO_TOKEN || '';
const LIVE = process.argv.includes('--live');

let pass = 0;
const fails = [];
const ok = (name, cond, detail = '') => {
  if (cond) { pass++; } else { fails.push(`  ✗ ${name}${detail ? '\n      ' + detail : ''}`); }
};

// ── 已实测确认的端点契约（2026-06，测试账号）──
const CONTRACTS = [
  { path: '/api/health', method: 'GET', auth: false, shape: ['status'] },
  { path: '/api/auth/status', method: 'GET', auth: false, shape: null },
  { path: '/api/auth/login', method: 'POST', auth: false, shape: null },
  { path: '/api/auth/me', method: 'GET', auth: true, shape: ['user'] },
  { path: '/api/studio/sessions', method: 'GET', auth: true, shape: ['sessions'] },
  { path: '/api/studio/sessions/usage', method: 'GET', auth: true, shape: null },
  { path: '/api/studio/chat-run/runs', method: 'POST', auth: true, shape: ['ok', 'output'] },
  { path: '/api/studio/group-chat/rooms', method: 'GET', auth: true, shape: ['rooms'] },
  { path: '/api/coding-agents', method: 'GET', auth: true, shape: ['tools'], note: '是 CLI 工具列表，不是 agents' },
  { path: '/api/hermes/config/models', method: 'GET', auth: true, shape: ['default', 'groups'] },
  { path: '/api/hermes/config/providers', method: 'POST', auth: true, shape: ['success'] },
  { path: '/api/hermes/jobs', method: 'GET', auth: true, shape: ['jobs'] },
  { path: '/api/hermes/kanban', method: 'GET', auth: true, shape: ['tasks'] },
  { path: '/api/ekko/memory', method: 'GET', auth: true, shape: null },
  // profile = 用户认知里的 Agent。openapi 里响应 schema 是空的，
  // 2026-10-06 已确认：GET 返回数组或 {profiles:[...]} 两种形状都兜。
  { path: '/api/hermes/profiles', method: 'GET', auth: true, shape: null, note: '形状不确定，代码里数组/{profiles}/{items}/{data} 四种都兜' },
  { path: '/api/hermes/profiles/active', method: 'PUT', auth: true, shape: null, note: 'body {name}，实测生效（切换当前激活 profile）' },
  // 阶段三新增。openapi 响应 schema 全空，字段靠「候选键逐个挑」容错解析
  { path: '/api/hermes/skills', method: 'GET', auth: true, shape: null, note: 'schema 空；解析器兜 skills/items/data/list/rows 五种外层键' },
  { path: '/api/hermes/mcp/servers', method: 'GET', auth: true, shape: null, note: 'schema 空；同上门到' },
  { path: '/api/studio/logs', method: 'GET', auth: true, shape: null, note: 'schema 空；同上门到' },
  { path: '/api/hermes/config/model', method: 'PUT', auth: true, shape: null, note: 'body {default,provider}，切 PC 默认模型（Models 页）' },
  { path: '/api/studio/search/sessions', method: 'GET', auth: true, shape: null, note: '?q=&limit=&source=，响应 schema 空，兜 {sessions:[]} 与裸数组' },
  { path: '/api/studio/files/read', method: 'GET', auth: true, shape: null, note: '?path=（相对工作区根），返回裸文本或 {content}' },
  { path: '/api/studio/workspace/folders', method: 'GET', auth: true, shape: null, note: '?path=，schema 空，兜 folders/items/data/list/entries' },
  { path: '/api/hermes/profiles/{name}/restart', method: 'POST', auth: true, shape: null, note: '重启 profile runtime（Profiles 页）' },
  // 终端：socket.io 命名空间 /terminal（不是 HTTP 端点）
  // 协议从安卓版 AppTerminal 反编译得到：capabilities → list → create → attach
  //   → input/resize/read/detach/close，每步带 lease
  // ⚠ 实测 2026-10-06：四种 auth 组合都回44/terminal,{"message":"terminal_forbidden"}
  //   → 是 PC 端服务端权限配置未开放，不是手机端 token 问题
  { path: '/terminal', method: 'WS', auth: true, shape: null, note: 'socket.io 命名空间；当前 PC 端 forbidden' }
];

// ── 静态检查：代码里不能出现这些已知错误的路径 ──
const BAD_PATHS = [
  { p: '/api/studio/coding-agents', why: '多写了 studio/ 前缀，服务端 404（实测）' },
  { p: '/api/studio/providers', why: '服务端 404，正确的是 /api/hermes/config/models（实测）' },
  { p: '/api/studio/hermes/', why: '多写了 studio/ 前缀' },
  { p: '/api/studio/ekko/', why: '多写了 studio/ 前缀' }
];

const files = [];
(function walk(dir) {
  for (const f of fs.readdirSync(dir)) {
    const full = path.join(dir, f);
    const st = fs.statSync(full);
    if (st.isDirectory()) { walk(full); }
    else if (f.endsWith('.ets')) { files.push(full); }
  }
})(SRC);

let allSrc = '';
for (const f of files) { allSrc += fs.readFileSync(f, 'utf8'); }

for (const bad of BAD_PATHS) {
  ok(`代码不含错误路径 ${bad.p}`, !allSrc.includes(`'${bad.p}'`), bad.why);
}

// 代码里用到的所有 /api 路径都应该在契约表里（提醒补契约）
const used = new Set();
for (const m of allSrc.matchAll(/['"](\/api\/[a-zA-Z0-9/_.{}-]+)['"]/g)) {
  used.add(m[1].replace(/\{[a-zA-Z]+\}/g, ''));
}
for (const p of used) {
  if (p.includes('{')) { continue; }
  const known = CONTRACTS.some(c => c.path === p);
  ok(`路径 ${p} 有契约记录`, known, '新增端点请同步到 CONTRACTS 并实测确认响应形状');
}

// ── 数据源对称性：list 有远程分支，get 也必须有 ──
//
// 本次真实踩过：RoomRepo.list() 有服务端分支（群聊列表能显示 PC 的房间），
// 但 RoomRepo.get() 没有 → 点进房间时查的是手机本地库 → 返回 null
// → 提示「群聊不存在」。
// **列表能看见、点进去说没有** —— 典型的「读方法漏了远程分支」。
// 编译器抓不到（两处代码都合法），只能静态扫。
const REPO_DIR = path.join(SRC_ROOT, 'data');
const REPO_FILES = ['Repos.ets', 'ExtendRepos.ets'];
let repoSrc = '';
for (const rf of REPO_FILES) {
  if (fs.existsSync(`${REPO_DIR}/${rf}`)) repoSrc += fs.readFileSync(`${REPO_DIR}/${rf}`, 'utf-8');
}
for (const cls of ['SessionRepo', 'MessageRepo', 'RoomRepo', 'RoomAgentRepo',
                   'GroupMessageRepo', 'ProviderRepo', 'AgentProfileRepo']) {
  const ci = repoSrc.indexOf(`export class ${cls} {`);
  if (ci < 0) continue;
  const ce = repoSrc.indexOf('\nexport class ', ci + 1);
  const seg = repoSrc.slice(ci, ce < 0 ? undefined : ce);

  const hasList = /static async list\(/.test(seg);
  const hasGet = /static async get\(/.test(seg);
  if (!hasList || !hasGet) continue;

  const grab = (name) => {
    const i = seg.indexOf(`static async ${name}(`);
    if (i < 0) return false;
    return seg.slice(i, i + 420).indexOf('isServerMode()') >= 0;
  };
  const listOk = grab('list');
  const getOk = grab('get');
  ok(`${cls}.get 与 .list 的数据源分支一致`,
     listOk === getOk,
     `list ${listOk ? '有' : '无'}远程分支，get ${getOk ? '有' : '无'}远程分支`
     + ` —— 列表能显示但点进去说「不存在」就是这么来的`);
}

// ── 实测（可选）──
if (LIVE) {
  if (!TOKEN) {
    fails.push('  ✗ --live 需要 EKKO_TOKEN 环境变量');
  } else {
    for (const c of CONTRACTS) {
      if (!c.auth) { continue; }
      // 只发 GET —— POST 端点（login / chat-run）用 GET 打必然 404，
      // 那不是契约错误，是方法不对。它们的响应形状靠人工实测记录在表里。
      if (c.method !== 'GET') { continue; }
      try {
        const r = await fetch(BASE + c.path, {
          headers: { 'Authorization': `Bearer ${TOKEN}` }
        });
        ok(`GET ${c.path} → 200`, r.status === 200, `实际 ${r.status}`);
        if (r.status === 200 && c.shape) {
          const d = await r.json();
          for (const k of c.shape) {
            ok(`${c.path} 响应含 "${k}"`, d[k] !== undefined,
              `实际顶层键: ${Object.keys(d).join(',')}`);
          }
        }
      } catch (e) {
        fails.push(`  ✗ GET ${c.path} 请求失败: ${e.message}`);
      }
    }
  }
}

console.log('─'.repeat(60));
console.log(`服务端端点契约：  通过 ${pass} · 失败 ${fails.length}${LIVE ? '（含实测）' : ''}`);
console.log('─'.repeat(60));
if (fails.length > 0) {
  console.log('\n发现问题：');
  fails.forEach(f => console.log(f));
  process.exit(1);
}
console.log(`\n>>> 全部通过（扫了 ${files.length} 个 .ets 文件，${used.size} 条路径）`);
