# 执行记录：deploy.sh 端口转发幂等化（SEQ16）

- 执行人：Claude（修复）
- 授权：ALEX seq 6「建议合适的，我这里都同意。API 不要混进项目，需要脱敏」——rport 工具化属 DSH 建议、ALEX 已广泛批准；`deploy.sh` 只加端口转发步骤，无 API/凭据
- 基线：`f1c07e4`（22 commits），工作区干净
- 来源：DSH `AUDIT-DSH-SEQ14-C3-RETEST-2026-10-10.md` 待办 (5)；DSH 复核建议「rport 工具化落在 `deploy.sh`，加幂等 `fport rm → rport`」
- 结论：**deploy.sh 新增幂等端口转发步骤，真机实测通过；冷构建 `BUILD SUCCESSFUL in 9 s 673 ms`，0 ERROR；HAP 1,752,590 B**
- 未动：F3（服务端草稿页首轮停止空转，P2 存疑）维持不动，等 ALEX 决定

---

## 一、改动内容

文件：`deploy.sh`（+19 / -5，净增 14 行）

| 位置 | 改动 |
|---|---|
| 步骤 1 之后 | 新增 **`==> 2/7 配置端口转发（幂等：先清理，再建立 rport）`** |
| 原步骤 2–6 | 顺延为 3/7–7/7 |

新增段落逻辑：

```bash
"$HDC" -t "$DEV" fport rm tcp:8748 tcp:8748 2>/dev/null || true
if "$HDC" -t "$DEV" rport tcp:8748 tcp:8748 >/dev/null 2>&1; then
  echo "   ✓ rport tcp:8748 → 宿主 8748 已建立"
else
  echo "   ⚠ rport 建立失败（不影响安装/启动，但 App 内「测试连接」会不通）"
fi
```

要点：

- **幂等清理**：`fport rm` 一条命令同时删除 forward 和 reverse 规则（实测确认），失败＝该映射本就不存在，`|| true` 容忍。
- **设备定向**：多设备环境下 hdc 必须 `-t "$DEV"`，否则 `rport` 报 `[Fail]ExecuteCommand need connect-key?`。实测两台设备（模拟器 `127.0.0.1:5555` + 真机 `5MT0226106008142`）时确实报错，加 `-t` 后通过。
- **非阻断失败**：rport 建立失败只打 ⚠ 不中断部署（构建/安装/启动仍继续），与 `deploy.sh` 的容错风格一致。

## 二、真机实测（不是只读推演）

测试环境：真机 `5MT0226106008142` 在线、模拟器 `127.0.0.1:5555` 在线（多设备场景）。

实测序列（与脚本逐行一致）：

```
fport rm -t 5MT0226106008142 tcp:8748 tcp:8748 → Remove forward ruler success
rport -t 5MT0226106008142 tcp:8748 tcp:8748  → Forwardport result:OK
fport ls  → 8748 [Reverse] / 8899 [Reverse] / 18748 [Forward] 全部恢复
```

结论：

- `fport rm` 能同时清掉 forward 与 reverse 规则（实测删除后 8748 [Reverse] 消失，重建后恢复）——证明「一条 fport rm 即幂等」成立。
- 端口转发在真机上实际生效：`8748` 反向转发重建成功，状态与测试前完全一致。

## 三、验证

| 项 | 结果 |
|---|---|
| `bash -n deploy.sh` | OK |
| 冷构建 `./build.sh release assembleHap` | `BUILD SUCCESSFUL in 9 s 673 ms`，0 ERROR |
| 产物 `entry-default-signed.hap` | 1,752,590 B |
| 工作区 | 仅 `M deploy.sh` + 新增 `docs/EXEC-SEQ16-...md` |

## 四、备份

- `.backups\seq16-deploy-rport-20261010\deploy.sh.bak`（6,579 B，修改前原件）

## 五、遗留（均非本轮范围）

- F3（P2 存疑）：服务端草稿页首轮点「停止」在服务端侧必然空转。**维持不动**，等 ALEX 决定。
- 用例 a（P1-NEW-1）本地路径复跑 + 用例 d 本地模式复跑：仍需假 Key + `hdc rport tcp:8899 tcp:8899` 方案闭环（`deploy.sh` 只处理 8748，不冲突）。
- README 基线 566 → 576 待更新。