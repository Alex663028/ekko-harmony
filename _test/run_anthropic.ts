/**
 * Anthropic 流事件解析回归。
 *
 * 🔴 为什么单独立一个文件
 *   LlmEngine.parseAnthropicFrame 之前**完全没有 Node 侧回归覆盖**
 *   （run_sse.ts 只测 Core.ets 的 OpenAI 侧 SSE 解析）。
 *   结果 Anthropic 分支漏掉了 message_stop 终止事件 ——
 *   流正常结束时 run.completed 不发，Orchestrator 干等 600s 兜底，
 *   inflight 里的 HttpRequest 也不 destroy，UI 气泡卡死转圈。
 *   这个文件就是把那段逻辑钉进回归网。
 */
import { parseAnthropicFrame } from './AnthropicParser.ts';

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

// ───── 终止事件（本次修复的核心）─────
// Anthropic Messages API 不发 data: [DONE]，终止信号是 event: message_stop。
// 之前 parseAnthropicFrame 没处理这个 type，返回 '' 被 continue 掉。
check('message_stop 返回 |STOP|', parseAnthropicFrame('{"type":"message_stop"}'), '|STOP|');
// data 段带完整 type 的网关也按终止处理
check('message_stop 带冗余字段仍终止',
  parseAnthropicFrame('{"type":"message_stop","message":null}'), '|STOP|');

// ───── 文本/思考增量 ─────
check('content_block_delta 文本', parseAnthropicFrame('{"type":"content_block_delta","delta":{"text":"你好"}}'), '|TEXT|你好');
check('content_block_delta 思考', parseAnthropicFrame('{"type":"content_block_delta","delta":{"thinking":"想"}}'), '|THINK|想');
// thinking 与 text 同在时思考优先（与既有实现一致）
check('delta 同时有 thinking 和 text 时思考优先',
  parseAnthropicFrame('{"type":"content_block_delta","delta":{"text":"a","thinking":"b"}}'), '|THINK|b');
check('delta 为空字符串返回空', parseAnthropicFrame('{"type":"content_block_delta","delta":{"text":""}}'), '');
check('delta 缺失返回空', parseAnthropicFrame('{"type":"content_block_delta"}'), '');

// ───── 用量 ─────
check('message_start 取输入 token',
  parseAnthropicFrame('{"type":"message_start","message":{"usage":{"input_tokens":100}}}'), '|IN|100');
check('message_start 无 usage 返回空',
  parseAnthropicFrame('{"type":"message_start","message":{}}'), '');
check('message_delta 取输出 token',
  parseAnthropicFrame('{"type":"message_delta","usage":{"output_tokens":50}}'), '|OUT|50');
// ───── 消费端前缀长度（2026-10-08 修复：|IN| 是 4 字符，slice(3) 会吞掉结尾竖线）─────
// 生产代码 LlmEngine.runAnthropic 用 frame.slice(4) 解析 |IN| 前缀。
// 回归只测 parseAnthropicFrame 没测消费端，导致 |IN| 的 slice 偏移错误漏网。
check('|IN| 前缀是 4 字符', '|IN|100'.slice(4), '100');
check('|OUT| 前缀是 5 字符', '|OUT|50'.slice(5), '50');
check('|ERR| 前缀是 5 字符', '|ERR|oops'.slice(5), 'oops');
check('|TEXT| 前缀是 6 字符', '|TEXT|你好'.slice(6), '你好');
check('|THINK| 前缀是 7 字符', '|THINK|想'.slice(7), '想');
check('|STOP| 前缀是 6 字符', '|STOP|'.slice(6), '');

// ───── 错误 ─────
check('error 事件带出文案',
  parseAnthropicFrame('{"type":"error","error":{"message":"配额耗尽"}}'), '|ERR|配额耗尽');
check('error 缺 message 返回空',
  parseAnthropicFrame('{"type":"error","error":{}}'), '');

// ───── 容错 ─────
check('空对象返回空', parseAnthropicFrame('{}'), '');
check('非法 JSON 不抛异常', parseAnthropicFrame('{oops'), '');
check('未知 type 返回空', parseAnthropicFrame('{"type":"ping"}'), '');
check('type 非字符串返回空', parseAnthropicFrame('{"type":123}'), '');

// ───── 端到端：一段真实 Anthropic 流逐事件喂进去 ─────
// 关键断言：最后一帧 message_stop 必须产出 |STOP|，
// 调用方（LlmEngine.runAnthropic）据此发 run.completed。
const stream: string[] = [
  '{"type":"message_start","message":{"usage":{"input_tokens":12}}}',
  '{"type":"content_block_delta","delta":{"text":"你"}}',
  '{"type":"content_block_delta","delta":{"text":"好"}}',
  '{"type":"message_delta","usage":{"output_tokens":8}}',
  '{"type":"message_stop"}'
];
let text = '';
let stopped = false;
let inTokens = 0;
let outTokens = 0;
for (const raw of stream) {
  const f = parseAnthropicFrame(raw);
  if (f.length === 0) continue;
  if (f === '|STOP|') { stopped = true; continue; }
  if (f.indexOf('|TEXT|') === 0) { text += f.slice(6); continue; }
  if (f.indexOf('|IN|') === 0) { inTokens = Number(f.slice(4)); continue; }
  if (f.indexOf('|OUT|') === 0) { outTokens = Number(f.slice(5)); continue; }
}
check('端到端: 拼出正文', text, '你好');
check('端到端: 收到终止信号', stopped, true);
check('端到端: 输入 token', inTokens, 12);
check('端到端: 输出 token', outTokens, 8);

console.log('─'.repeat(56));
console.log(`Anthropic 解析回归：  通过 ${pass} · 失败 ${fail}`);
console.log('─'.repeat(56));
if (fail > 0) {
  console.log('\n失败详情：');
  failures.forEach((x) => console.log(x));
  process.exit(1);
}
console.log('\n>>> 全部通过');
