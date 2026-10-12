#!/usr/bin/env node
/**
 * 一次性同步所有「从生产代码抽取的测试副本」。
 *
 * 🔴 为什么必须统一入口（2026-10-07 收尾时发现）
 *   之前有两个生成器都写 `_test/SocketClient.ts`：
 *     - extract.mjs（通用，配置驱动）
 *     - sync_socket_codec.mjs（专用，硬编码区间）
 *   两者产物只差一个 `buildOriginHeader`（无害纯函数），
 *   但**跑错顺序就不知道测的是哪一版**，很容易又测到旧逻辑 ——
 *   这正是当初「手工副本」导致 bug 被锁住的老问题。
 *   ⇒ 合成这一个脚本，跑一次全齐。
 *
 * 用法：node _test/sync_all.mjs
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { execFileSync } from 'node:child_process';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const self = fileURLToPath(import.meta.url);

/** 跑一个子脚本，失败直接抛（不要静默continue —— 测旧逻辑比不测更危险） */
function run(script, args) {
  console.log(`→ ${path.basename(script)} ${args.join(' ')}`);
  execFileSync(process.execPath, [script, ...args], {
    cwd: path.join(__dirname, '..'),
    stdio: 'inherit'
  });
}

// ① 通用抽取器：SocketClient（协议编解码）+ Core（纯逻辑）
run(path.join(__dirname, 'extract.mjs'), [path.join(__dirname, 'extract-socket.json')]);

// ①b LlmEngine.parseAnthropicFrame 的镜像（AnthropicParser.ts）
//    纯 string→string，无 SDK 依赖，跑 Node 回归。
//    🔴 与 SocketClient.ts 不同，这个不能用 extract.mjs 抽（LlmEngine.ets
//    里没有 // ── banner 切段，extract 按 banner 选段会抽出 0 字节）。
//    改为「按锚点行精确截取」：找到 parseAnthropicFrame 声明行，
//    大括号配平到函数尾，再向上吞掉 JSDoc。锚点行内容写死在脚本里，
//    函数一改名这里就报长度不足 —— 宁可失败也不要静默测旧代码。
run(path.join(__dirname, 'extract_anthropic.mjs'), []);

// ② Core.ts 是 Core.ets 的完整镜像（run.ts / run_ext.ts 依赖）
const coreEts = path.join(__dirname, '..', 'entry', 'src', 'main', 'ets', 'common', 'Core.ets');
const coreTs = path.join(__dirname, 'Core.ts');
fs.writeFileSync(coreTs, fs.readFileSync(coreEts, 'utf8').replace(/^﻿/, ''), 'utf8');
console.log(`→ Core.ts已同步（${fs.statSync(coreTs).size} 字节）`);

// ③ 自检：产物必须存在且不太小（太小说明抽取失败，测了个空壳）
for (const f of ['SocketClient.ts', 'Core.ts']) {
  const p = path.join(__dirname, f);
  const size = fs.statSync(p).size;
  if (size < 1000) {
    console.error(`✗ ${f} 只有 ${size} 字节，抽取多半失败了 —— 拒绝继续`);
    process.exit(1);
  }
  console.log(`  ✓ ${f} ${size} 字节`);
}

console.log('\n全部抽取产物已同步，接下来可以跑守卫：');
console.log('  node --experimental-transform-types _test/run_socket.ts');
console.log('  node _test/run_endpoint_guard.mjs');
console.log('  node --experimental-transform-types _test/run_uiguard.ts');