/**
 * SQL 参数配对守卫。
 *
 * 背景：`RoomAgentRepo.upsert` 曾把 `agent.id` 误传给 room_id 列，
 * 编译能过、运行不报错，但**群聊里的 Agent 存进去就永远查不出来**
 * （查询是 WHERE room_id = ?），功能整体静默失效。
 *
 * 这类 bug 编译器抓不到，只能用静态检查兜住。
 * 做法：把 SQL 占位符个数与实参个数解析出来对比。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * 源码根目录，**按本文件位置解析**。
 *
 * 🔴 不能写死绝对路径（2026-10-07 交付时发现）
 *   原本是写死 '<项目根>/entry/src/main/ets'，复制项目后扫不到文件
 *   → 守卫「通过」但实际什么都没检查。
 */
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SRC_ROOT = path.join(__dirname, '..', 'entry', 'src', 'main', 'ets');

let checked = 0;
const problems: string[] = [];

interface Call {
  file: string;
  line: number;
  sql: string;
  argsStart: number;
  lineNo: number;
}

/** 找出所有 executeSql(`...`, [ ... ]) 形式的调用 */
function findCalls(text: string, file: string): Call[] {
  const out: Call[] = [];
  const lines = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    if (!lines[i].includes('executeSql(')) {
      continue;
    }
    // 收集从 executeSql( 开始的完整语句（跨行）
    let stmt = '';
    let depth = 0;
    let started = false;
    for (let j = i; j < lines.length && j < i + 40; j++) {
      for (const c of lines[j]) {
        if (c === '(') {
          depth++;
          started = true;
        } else if (c === ')') {
          depth--;
        }
      }
      stmt += (j > i ? '\n' : '') + lines[j];
      if (started && depth === 0) {
        break;
      }
    }
    out.push({ file, line: i + 1, sql: stmt, argsStart: 0, lineNo: i + 1 });
  }
  return out;
}

/** 数SQL 模板串里的 ? 占位符（跳过字符串字面量里的问号） */
function countPlaceholders(sql: string): number {
  const m = sql.match(/`([^`]*)`/);
  if (m === null) {
    return -1;
  }
  let n = 0;
  for (const ch of m[1]) {
    if (ch === '?') {
      n++;
    }
  }
  return n;
}

/** 数实参个数：取 [ ... ] 里的顶层逗号分隔项 */
function countArgs(stmt: string): number {
  const b = stmt.indexOf('[');
  if (b < 0) {
    return -1;
  }
  let depth = 0;
  let items = 0;
  let hasContent = false;
  let inStr = '';
  for (let i = b; i < stmt.length; i++) {
    const c = stmt[i];
    if (inStr.length > 0) {
      if (c === inStr) {
        inStr = '';
      }
      continue;
    }
    if (c === '\'' || c === '"' || c === '`') {
      inStr = c;
      hasContent = true;
      continue;
    }
    if (c === '(' || c === '[') {
      depth++;
      if (depth === 1) {
        continue;
      }
    } else if (c === ')' || c === ']') {
      depth--;
      if (depth === 0) {
        break;
      }
    }
    if (c === ',' && depth === 1) {
      items++;
      continue;
    }
    if (depth === 1 && !/\s/.test(c)) {
      hasContent = true;
    }
  }
  return hasContent ? items + 1 : 0;
}

function walk(dir: string): void {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) {
      walk(p);
    } else if (e.name.endsWith('.ets')) {
      const text = fs.readFileSync(p, 'utf8');
      const rel = p.replace(SRC_ROOT + '/', '');
      for (const c of findCalls(text, rel)) {
        const ph = countPlaceholders(c.sql);
        const args = countArgs(c.sql);
        if (ph < 0 || args < 0) {
          continue;
        }
        checked++;
        if (ph !== args) {
          problems.push(
            `  ✗ ${c.file}:${c.lineNo} 占位符 ${ph} 个，实参 ${args} 个 —— 数量不匹配\n` +
            `     ${c.sql.split('\n')[0].trim().slice(0, 90)}`
          );
        }
      }
    }
  }
}

walk(SRC_ROOT);

console.log('─'.repeat(56));
console.log(`SQL 参数配对：  检查 ${checked} 处 executeSql`);
console.log('─'.repeat(56));
if (problems.length > 0) {
  console.log('\n发现问题：');
  problems.forEach((p) => console.log(p));
  process.exit(1);
}
console.log('\n>>> 全部匹配');

/**
 * 额外守卫：关键 SQL 的列名 ↔ 实参必须按位置对应。
 *
 * 为什么必须有这条：
 * 最初只做了「占位符数量 == 实参数量」检查，但 `RoomAgentRepo.upsert` 的真实 bug是
 * **数量对、值错** —— room_id 列传了 agent.id。所以数量检查完全放过了它。
 * 教训：这类问题必须断言「某列对应的实参里出现了正确的字段名」，
 * 数量对不等于值对。
 *
 * 断言方式：对每个关心的列名，检查它后面第 N 个实参是不是预期的字段。
 */
console.log('\n--- 列↔实参 位置断言 ---');
let assertPass = 0;
const assertFail: string[] = [];

function assertArgAfter(file: string, marker: string, after: number, expected: string): void {
  const text = fs.readFileSync(`${SRC_ROOT}/${file}`, 'utf8');
  const at = text.indexOf(marker);
  if (at < 0) {
    assertFail.push(`  ✗ ${file} 找不到标记：${marker.slice(0, 50)}`);
    return;
  }
  // 取该 SQL 里的实参列表
  const b = text.indexOf('[', at);
  let depth = 0;
  let args: string[] = [];
  let cur = '';
  let inStr = '';
  for (let i = b; i < text.length && i < b + 2000; i++) {
    const c = text[i];
    if (inStr.length > 0) {
      if (c === inStr) {
        inStr = '';
      }
      cur += c;
      continue;
    }
    if (c === '\'' || c === '"' || c === '`') {
      inStr = c;
      cur += c;
      continue;
    }
    if (c === '(' || c === '[') {
      depth++;
      if (depth === 1) {
        continue;
      }
    } else if (c === ')' || c === ']') {
      depth--;
      if (depth === 0) {
        break;
      }
    }
    if (c === ',' && depth === 1) {
      args.push(cur.trim());
      cur = '';
      continue;
    }
    cur += c;
  }
  if (cur.trim().length > 0) {
    args.push(cur.trim());
  }
  const got = args[after] ?? '(缺失)';
  if (got.indexOf(expected) >= 0) {
    assertPass++;
  } else {
    assertFail.push(
      `  ✗ ${file}: 实参 #${after} 应含 "${expected}"，实际是 "${got}"\n` +
      `     （列名与实参错位：编译能过、运行不报错，但功能静默失效）`
    );
  }
}

// ↓ 每一行的下标必须与源码里SQL 的列顺序严格一致（照抄自实际代码）
// gc_room_agents: (id, room_id, agent_id, agent, ...) → #1 必须是 agent.roomId
assertArgAfter('data/Repos.ets', 'INSERT OR REPLACE INTO gc_room_agents', 1, 'agent.roomId');
// sessions: (id, title, source, model, provider, message_count, created_at, updated_at)
assertArgAfter('data/Repos.ets', 'INSERT INTO sessions', 1, 'title');
// messages: (id, session_id, run_id, role, ...) → #1 是 sessionId
assertArgAfter('data/Repos.ets', 'INSERT OR REPLACE INTO messages', 1, 'msg.sessionId');
// gc_messages: (id, room_id, sender_name, ...) → #1 是 roomId
assertArgAfter('data/Repos.ets', 'INSERT OR REPLACE INTO gc_messages', 1, 'roomId');
// prefs: (key, value)
assertArgAfter('data/ExtendRepos.ets', 'INSERT OR REPLACE INTO prefs', 1, 'value');
// session_shares: (token, session_id, title, ...)
assertArgAfter('data/ExtendRepos.ets', 'INSERT OR REPLACE INTO session_shares', 1, 'sessionId');
// memories: (id, scope, scope_id, kind, content, ...)
assertArgAfter('data/ExtendRepos.ets', 'INSERT OR REPLACE INTO memories', 1, 'scope');
// attachments: (id, session_id, room_id, message_id, ...)
assertArgAfter('data/ExtendRepos.ets', 'INSERT OR REPLACE INTO attachments', 1, 'sessionId');
// jobs: (id, name, cron, session_id, room_id, agent_id, ...) → #3 是 sessionId
assertArgAfter('data/ExtendRepos.ets', 'INSERT OR REPLACE INTO jobs', 3, 'sessionId');
// usage_records: (id, session_id, room_id, agent_id, ...)
// 注：这条是 INSERT INTO（非 OR REPLACE），早期重构后改过，断言标记没跟上 →
//     长期「找不到标记」静默漏测。P1-SEQ7 复盘修正。
assertArgAfter('data/ExtendRepos.ets', 'INSERT INTO usage_records', 1, 'sessionId');

if (assertFail.length > 0) {
  console.log(assertFail.join('\n'));
  process.exit(1);
}
console.log(`  ${assertPass} 项列↔实参断言通过`);
console.log('>>> 列↔实参 位置断言全部通过');