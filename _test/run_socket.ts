/**
 * Socket.IO 协议编解码回归测试。
 * 帧格式错一位就全盘不通，且没有编译器兜底，必须测。
 */
import {
  decodeFrame, encodeMessage, encodeConnect, encodeConnectAuth, eventNameOf, eventArgsOf,
  buildWsUrl, EnginePacket, SUB_CONNECT_ERROR,
} from './SocketClient.ts';

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

// ───── 解码 ─────
let f = decodeFrame('4/chat-run,2["message.delta",{"delta":"你"}]');
check('解码命名空间', f?.namespace, '/chat-run');
check('解码 payload', f?.payload, '["message.delta",{"delta":"你"}]');
check('无 ack 时 ackId=-1', f?.ackId, -1);
check('解码类型', f?.type, EnginePacket.MESSAGE);

f = decodeFrame('4/group-chat,72["join",{"roomId":"r1"}]');
check('解码带 ack', f?.ackId, 7);
check('解码带 ack payload', f?.payload, '["join",{"roomId":"r1"}]');

f = decodeFrame('42["event",1]');
check('默认命名空间', f?.namespace, '/');
check('默认命名空间 payload', f?.payload, '["event",1]');

f = decodeFrame('2');
check('PING 帧', f?.type, EnginePacket.PING);
check('PING 无 payload', f?.payload, '');

f = decodeFrame('3');
check('PONG 帧', f?.type, EnginePacket.PONG);

check('空串解出 null', decodeFrame(''), null);
check('脏帧解出 null', decodeFrame('4/chat-run,2["broken"'), null);

// ───── 编码 ─────
// 🔴 socket.io v5 帧结构是 `4<subType><ns>,<ackId><payload>` —— subType 紧跟 '4'。
//之前非默认命名空间生成 `4<ns>,<ackId><subType>`（B 格式），
//    服务端解析不了、发完直接关连接（实测：群聊 join 发出后 2ms 就断）。
check('编码无 ack', encodeMessage('/chat-run', -1, '["abort"]'), '42/chat-run,["abort"]');
check('编码带 ack', encodeMessage('/group-chat', 7, '["join",{}]'), '42/group-chat,7["join",{}]');
check('编码默认命名空间', encodeMessage('/', -1, '["x"]'), '42["x"]');
check('编码默认命名空间带 ack', encodeMessage('/', 5, '["x"]'), '425["x"]');
check('编码默认命名空间可解码', decodeFrame('42["x"]')?.payload, '["x"]');
check('编码默认命名空间可取事件名',
  eventNameOf(decodeFrame(encodeMessage('/', -1, '["ev",1]'))!.payload), 'ev');
// 🔴 回归点：命名空间帧必须是 `4<subType><ns>,`，不是 `4<ns>,<subType>`
check('命名空间帧 subType 在 ns 前',
  encodeMessage('/group-chat', -1, '["join",{}]'), '42/group-chat,["join",{}]');
check('命名空间帧可解码 ns', decodeFrame('42/group-chat,["join",{}]')?.namespace, '/group-chat');
check('命名空间帧可解码 payload', decodeFrame('42/group-chat,["join",{}]')?.payload, '["join",{}]');
// ⚠ 回归点：曾漏了子类型 0，服务端回 44/chat-run,{"message":"Authentication failed"}
check('编码 CONNECT 包', encodeConnect('/chat-run'), '40/chat-run,');
check('编码 CONNECT 默认命名空间', encodeConnect('/'), '40');

// ───── 服务端下行帧格式（与服务端抓包严格对齐，2026-10-07）───
// ⚠ 实测：**上行与下行是同一套格式** `4<subType><ns>,<ackId><payload>`。
//    之前 decodeFrame 只认 `4<ns>,<ackId><subType>`，
//    导致下行帧 ns 恒为 '/'、payload 吞掉整段，
//    群聊的命名空间回执永远收不到 → join 被丢弃 → 界面一条消息都没有。
check('下行:默认 ns CONNECT', decodeFrame('40{"sid":"X"}')?.namespace, '/');
check('下行:命名空间 CONNECT 的 ns', decodeFrame('40/group-chat,{"sid":"X"}')?.namespace, '/group-chat');
check('下行:命名空间 CONNECT 的 payload', decodeFrame('40/group-chat,{"sid":"X"}')?.payload, '{"sid":"X"}');
check('下行:命名空间 EVENT 的 ns', decodeFrame('42/chat-run,["m",{}]')?.namespace, '/chat-run');
check('下行:命名空间 EVENT 的 payload', decodeFrame('42/chat-run,["m",{}]')?.payload, '["m",{}]');
check('下行:带 ack 的 ACK', decodeFrame('43/group-chat,7["r",1]')?.ackId, 7);
check('下行:带 ack 的 ACK subType', decodeFrame('43/group-chat,7["r",1]')?.subType, '3');
//⚠ 回归点：曾漏了子类型 0，变成 `4{"token":...}`，
//    服务端静默丢弃（server.log 完全无记录），auth 永远超时。
check('编码 auth CONNECT', encodeConnectAuth('/chat-run', 'T1'), '40{"token":"T1"}');
// 命名空间 CONNECT 也必须带 auth（握手 query 里带了不算）
check('命名空间 CONNECT 带 auth', encodeConnect('/chat-run', 'T2'), '40/chat-run,{"token":"T2"}');
check('命名空间 CONNECT 无 auth', encodeConnect('/chat-run'), '40/chat-run,');

// ───── 往返 ─────
const orig = { event: 'run.started', run_id: 'r1' };
const encoded = encodeMessage('/chat-run', 3, JSON.stringify(['run.started', orig]));
const decoded = decodeFrame(encoded);
check('编解码往返事件名', eventNameOf(decoded!.payload), 'run.started');
check('编解码往返参数', eventArgsOf(decoded!.payload), [orig]);

// ───── 事件名与参数 ─────
check('事件名解析', eventNameOf('["message.delta",{}]'), 'message.delta');
check('事件名解析空数组', eventNameOf('[]'), '');
check('事件名解析非法 JSON', eventNameOf('{oops'), '');
check('参数解析', eventArgsOf('["join",{"roomId":"r1"},5]'), [{ roomId: 'r1' }, 5]);
check('参数解析无参', eventArgsOf('["ping"]'), []);
check('参数解析非法 JSON', eventArgsOf('{oops'), []);

// ───── URL 构造 ─────
//⚠ socket.io 的路径**恒为 /socket.io/**，namespace 不进 URL，
//   而是握手之后用 `40<ns>,` 帧在 socket.io 层协商。
//   （踩过：曾生成 /chat-run?token=... 服务端直接 hang up。）
//⚠ token **不走 query**：URL 会出现在代理/访问日志里，等于把登录凭证写进
//   传输路径；实测服务端只认 socket.io 的 auth 帧，query 里的 token 根本不读。
//   所以 buildWsUrl 只有 2 个参数，token 断言在 auth 帧那一组（见下方）。
//   这两条曾经按 3 参数写断言，与 2 参数的实现签名对不上 → 静默漏测，
//   由 P1-SEQ7 复盘时发现并改正。
check('http → ws', buildWsUrl('http://127.0.0.1:8748', '/chat-run'),
  'ws://127.0.0.1:8748/socket.io/?EIO=4&transport=websocket');
check('https → wss', buildWsUrl('https://studio.local', '/group-chat'),
  'wss://studio.local/socket.io/?EIO=4&transport=websocket');
check('去尾斜杠', buildWsUrl('http://h:1///', '/chat-run'),
  'ws://h:1/socket.io/?EIO=4&transport=websocket');
check('默认命名空间不带斜杠', buildWsUrl('http://h:1', '/'),
  'ws://h:1/socket.io/?EIO=4&transport=websocket');

// ───── 原版真实报文对齐（来自逆向记录） ─────
// 原版群聊握手：命名空间 /group-chat，token 走 handshake.auth 或 query
const gc = decodeFrame('4/group-chat,2["message",{"roomId":"mucsvz4qqwyweg","content":"@codex 干活"}]');
check('原版群聊报文可解码', gc?.namespace, '/group-chat');
const gcArgs = eventArgsOf(gc!.payload) as Array<Record<string, string>>;
const gcArg0 = gcArgs[0];
check('原版报文 roomId', gcArg0 !== undefined ? gcArg0.roomId : undefined, 'mucsvz4qqwyweg');
check('原版报文 content', gcArg0 !== undefined ? gcArg0.content : undefined, '@codex 干活');

// 单聊事件流：run.started → message.delta → run.completed
const ev1 = decodeFrame(encodeMessage('/chat-run', -1,
  JSON.stringify(['run.started', { run_id: 'r9', session_id: 's1' }])));
check('单聊 run.started', eventNameOf(ev1!.payload), 'run.started');
const ev2 = decodeFrame(encodeMessage('/chat-run', -1,
  JSON.stringify(['message.delta', { run_id: 'r9', delta: '好' }])));
check('单聊 message.delta', eventNameOf(ev2!.payload), 'message.delta');
const ev3 = decodeFrame(encodeMessage('/chat-run', -1,
  JSON.stringify(['run.completed', { run_id: 'r9', output: '好' }])));
check('单聊 run.completed', eventNameOf(ev3!.payload), 'run.completed');

// ───── CONNECT_ERROR：auth 被拒时服务端下发的真实帧 ─────
// socket.io-parser protocol 5：1=DISCONNECT 4=CONNECT_ERROR。
// 之前常量误写成 SUB_CONNECT_ERROR='1'，onFrame 里这条帧永远比对不上，
// UI 拿不到 "Unauthorized" 只能空等 8s 超时。
const ce = decodeFrame('44/group-chat,{"message":"Unauthorized"}');
check('CONNECT_ERROR 解出 subType=4', ce?.subType, '4');
check('CONNECT_ERROR 常量与解码一致', SUB_CONNECT_ERROR, '4');
check('CONNECT_ERROR ns', ce?.namespace, '/group-chat');
check('CONNECT_ERROR payload', ce?.payload, '{"message":"Unauthorized"}');
check('SUB_DISCONNECT 不再冒充 CONNECT_ERROR', '1' === '4', false);

console.log('─'.repeat(56));
console.log(`Socket.IO 协议回归：  通过 ${pass} · 失败 ${fail}`);
console.log('─'.repeat(56));
if (fail > 0) {
  console.log('\n失败详情：');
  failures.forEach((x) => console.log(x));
  process.exit(1);
}
console.log('\n>>> 全部通过');