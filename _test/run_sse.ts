/**
 * SSE 流式解析回归测试（追加到 Core 纯逻辑层）。
 * 这是最容易写错的一块：分片边界、多行 data、终止标记。
 */
import {
  parseSseChunk, isSseDone, extractDelta, extractUsage, hasUsage,
  extractSseError, type UsageLite,
} from './Core.ts';

let pass = 0;
let fail = 0;
const failures: string[] = [];

function check(name: string, actual: unknown, expected: unknown): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) { pass++; } else {
    fail++;
    failures.push(`  ✗ ${name}\n     实际 ${a}\n     期望 ${e}`);
  }
}

function ok(name: string, cond: boolean, detail: string = ''): void {
  if (cond) { pass++; } else {
    fail++;
    failures.push(`  ✗ ${name}${detail ? ' — ' + detail : ''}`);
  }
}

// ───── 基本解析 ─────
let r = parseSseChunk('data: {"a":1}\n\n');
check('单事件解析', r.events, ['{"a":1}']);
check('单事件后无残留', r.rest, '');

r = parseSseChunk('data: A\n\ndata: B\n\n');
check('多事件', r.events, ['A', 'B']);

r = parseSseChunk('data: A\n\ndata: B\n\ndata: C');
check('尾部残缺事件留在 rest', r.events, ['A', 'B']);
check('rest 保留未闭合部分', r.rest, 'data: C');

// ───── CRLF ─────
r = parseSseChunk('data: A\r\n\r\ndata: B\r\n\r\n');
check('CRLF 边界', r.events, ['A', 'B']);

// ───── 分片到达（最容易错） ─────
const full = 'data: {"d":"你好"}\n\ndata: {"d":"世界"}\n\n';
// 逐字节喂
let buf = '';
const collected: string[] = [];
for (const ch of full) {
  buf += ch;
  const res = parseSseChunk(buf);
  buf = res.rest;
  collected.push(...res.events);
}
check('逐字节喂完事件数正确', collected.length, 2);
check('逐字节喂完内容正确', collected, ['{"d":"你好"}', '{"d":"世界"}']);
ok('逐字节喂完无残留', buf === '');

// ───── 注释/心跳 ─────
r = parseSseChunk(': ping\n\ndata: A\n\n');
check('忽略注释行', r.events, ['A']);

r = parseSseChunk('event: message\nid: 1\ndata: A\n\n');
check('忽略 event/id 字段只取 data', r.events, ['A']);

// ───── 多行 data ─────
r = parseSseChunk('data: line1\ndata: line2\n\n');
check('多行 data 用\\n 拼接', r.events, ['line1\nline2']);

// ───── 终止标记 ─────
ok('识别 [DONE]', isSseDone('[DONE]'));
ok('识别带空格的 [DONE]', isSseDone(' [DONE] '));
ok('非 DONE', isSseDone('{"a":1}') === false);

// ───── delta 提取 ─────
check('提取 content',
  extractDelta('{"choices":[{"delta":{"content":"你好"}}]}'), '你好');
check('提取空 content',
  extractDelta('{"choices":[{"delta":{"content":""}}]}'), '');
check('提取 reasoning_content 优先',
  extractDelta('{"choices":[{"delta":{"reasoning_content":"想","content":"答"}}]}'), '想');
check('无 reasoning 时回落 content',
  extractDelta('{"choices":[{"delta":{"content":"答"}}]}'), '答');
check('completions 风格 text 字段',
  extractDelta('{"choices":[{"text":"hi"}]}'), 'hi');
check('choices 为空返回 null',
  extractDelta('{"choices":[]}'), '');
check('非法 JSON 返回 null', extractDelta('{oops'), '');
check('[DONE] 返回 null', extractDelta('[DONE]'), '');
check('错误对象返回 null',
  extractDelta('{"error":{"message":"配额耗尽"}}'), '');
check('无 choices 字段返回 null', extractDelta('{}'), '');

// ───── usage 提取 ─────
check('usage 提取',
  extractUsage('{"usage":{"prompt_tokens":100,"completion_tokens":30}}').inputTokens, 100);
check('usage 提取 output', extractUsage('{"usage":{"prompt_tokens":100,"completion_tokens":30}}').outputTokens, 30);
check('hasUsage 有 usage', hasUsage('{"usage":{"prompt_tokens":100}}'), true);
check('hasUsage 无 usage', hasUsage('{"choices":[]}'), false);
check('SSE 错误文案', extractSseError('{"error":{"message":"配额耗尽"}}'), '配额耗尽');
check('无 usage 时 input 为 0', extractUsage('{"choices":[]}').inputTokens, 0);
check('DONE 时 input 为 0', extractUsage('[DONE]').inputTokens, 0);

// ───── 真实场景：完整一轮流 ─────
const realistic = [
  'data: {"choices":[{"delta":{"role":"assistant"}}]}',
  'data: {"choices":[{"delta":{"content":"你"}}]}',
  'data: {"choices":[{"delta":{"content":"好"}}]}',
  'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}',
  'data: {"usage":{"prompt_tokens":12,"completion_tokens":2}}',
  'data: [DONE]'
].map((s) => `${s}\n\n`).join('');

let acc = '';
let out = '';
let gotUsage: number = -1;
let p = 0;
while (p < realistic.length) {
  // 模拟不规则分片
  const step = [3, 17, 5, 40, 9, 60][p % 6];
  acc += realistic.slice(p, p + step);
  p += step;
  const res = parseSseChunk(acc);
  acc = res.rest;
  for (const ev of res.events) {
    if (isSseDone(ev)) { continue; }
    const d = extractDelta(ev);
    if (d !== null && d.length > 0) { out += d; }
    const u = extractUsage(ev);
    if (u !== null) { gotUsage = u.inputTokens; }
  }
}
check('完整流拼出正文', out, '你好');
check('完整流拿到 usage', gotUsage, 12);
ok('完整流无残留', acc === '');

console.log('─'.repeat(56));
console.log(`SSE 解析回归：  通过 ${pass} · 失败 ${fail}`);
console.log('─'.repeat(56));
if (fail > 0) {
  console.log('\n失败详情：');
  failures.forEach((f) => console.log(f));
  process.exit(1);
}
console.log('\n>>> 全部通过');