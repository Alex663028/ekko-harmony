/**
 * API Key 运行时加密存储（③ 工单：API Key 存储态脱敏 + 存量迁移）。
 *
 * 目标：`providers.api_key` 列不再落明文，落的是 AES-GCM-256 密文；
 *      明文只存在于内存中的 Provider 对象（页面表单、请求头）。
 *
 * 方案：
 *   - 主密钥：32 字节随机数，存入系统 keystore（@ohos.security.asset，应用私有，
 *     root 也无法直接读出）。与 AppStore 令牌存储同源同机制。
 *   - 算法：AES-GCM-256（cryptoFramework）。GCM 自带完整性校验（authTag），
 *     密文被篡改/密钥不匹配时 doFinal 抛错。
 *   - 落库格式：`ekko:v1:<base64(iv)>:<base64(ciphertext || authTag)>`。
 *     前缀 `ekko:v1:` 用于区分存量明文（无前缀）与加密后的值，支撑惰性迁移。
 *   - 失败策略：可用性优先。解密失败（密钥丢失/格式损坏）时返回空串并告警，
 *     不抛异常 —— 调用方看到空 key 会提示「请重新填写 API Key」，不会崩溃。
 *     加密时 keystore 不可用（缺权限/锁屏/系统异常）也**不抛错**，降级为明文落库
 *     并告警（对齐 AppStore.setToken 的可用性优先策略），设备解锁后再次写入自动恢复加密。
 *     仅当 keystore 正常但加密过程本身失败时才抛错（fail-closed），防止数据损坏。
 */

import cryptoFramework from '@ohos.security.cryptoFramework';
import asset from '@ohos.security.asset';
import util from '@ohos.util';
import hilog from '@ohos.hilog';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 0xE000;
const DOMAIN = 'EkkoStore';

/** 主密钥在 keystore 中的别名（应用私有） */
const KEY_ALIAS = 'ekko.studio.apiKeyMasterKey';
/** GCM IV 长度：NIST SP 800-38D 推荐 96 bit */
const GCM_IV_LENGTH = 12;
/** 落库密文前缀：用于识别「已加密」与「存量明文」 */
export const API_KEY_CIPHER_PREFIX = 'ekko:v1:';

/** GCM 参数（每次加密随机生成新 IV） */
class GcmCryptoParams {
  iv: Uint8Array;
  aad: Uint8Array;
  authTag: Uint8Array;
  constructor(iv: Uint8Array, aad: Uint8Array, authTag: Uint8Array) {
    this.iv = iv;
    this.aad = aad;
    this.authTag = authTag;
  }
}

/** base64 编码（标准 base64，与 Core.ets 的 base64Url 区分） */
function b64Encode(bytes: Uint8Array): string {
  const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let out = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const b0 = bytes[i];
    const b1 = i + 1 < bytes.length ? bytes[i + 1] : 0;
    const b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
    out += B64.charAt(b0 >> 2);
    out += B64.charAt(((b0 & 0x03) << 4) | (b1 >> 4));
    out += i + 1 < bytes.length ? B64.charAt(((b1 & 0x0f) << 2) | (b2 >> 6)) : '=';
    out += i + 2 < bytes.length ? B64.charAt(b2 & 0x3f) : '=';
  }
  return out;
}

/** base64 解码 → Uint8Array */
function b64Decode(b64: string): Uint8Array {
  const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const lut: number[] = [];
  for (let i = 0; i < 128; i++) {
    lut[i] = -1;
  }
  for (let i = 0; i < B64.length; i++) {
    lut[B64.charCodeAt(i)] = i;
  }
  const out: number[] = [];
  let acc = 0;
  let bits = 0;
  for (let i = 0; i < b64.length; i++) {
    const code = b64.charCodeAt(i);
    if (code === 61) {
      break; // '='
    }
    if (code >= 128) {
      continue;
    }
    const v = lut[code];
    if (v < 0) {
      continue;
    }
    acc = (acc << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push((acc >> bits) & 0xff);
    }
  }
  return new Uint8Array(out);
}

/**
 * keystore 查询参数：按别名定位主密钥，并要求返回 SECRET 明文。
 * 必须带 RETURN_TYPE = ReturnType.ALL：asset 服务端对不带该 tag 的 query
 * 默认走 query_attrs 并主动剥掉 SECRET（有行无密文），导致主密钥永远读不回
 * —— 这是「add 成功后每次重查都撞 24000003」的真正上游根因（seq22-R2）。
 * 本方法只被 asset.query 使用（getOrCreateMasterKey 内），可安全携带。
 */
function masterKeyQuery(): Map<asset.Tag, asset.Value> {
  return new Map<asset.Tag, asset.Value>([
    [asset.Tag.ALIAS, new util.TextEncoder().encode(KEY_ALIAS)],
    [asset.Tag.RETURN_TYPE, asset.ReturnType.ALL]
  ]);
}

/**
 * asset 错误码判别使用 SDK 导出的 ErrorCode 枚举（@ohos.security.asset）：
 * NOT_FOUND=24000002（query 无匹配资产）、DUPLICATED=24000003（add 撞已存在别名）。
 * 日志统一双通道：BusinessError.code 可能缺失，故打 `code ?? '-'` 的同时附 String(e)
 * （String(e) 只是纯文本描述，不带数字前缀 —— 数字前缀来自本模块的 `code ?? '-'` 拼接）。
 */

/**
 * 取主密钥。不存在则生成 32 字节随机 AES-256 密钥并写入 keystore。
 * 返回 null 表示 keystore 不可用（只告警，不抛错 —— 解密失败由调用方兜底）。
 */
async function getOrCreateMasterKey(): Promise<cryptoFramework.SymKey | null> {
  // asset.query 在无匹配资产时抛 24000002（NOT_FOUND），而不是返回空数组。
  // 首次调用（主密钥还不存在）必须先捕获该错误，否则「生成并写入」分支永远不会执行，
  // 加密路径会静默降级为明文落库。这是 ③ 在真机上零生效的根因。
  // 其他错误（权限缺失/系统异常）继续走「尝试重新创建」，由下面的 add 结果兜底。
  try {
    const rows = await asset.query(masterKeyQuery());
    if (rows.length > 0) {
      const v = rows[0].get(asset.Tag.SECRET);
      if (v !== undefined && v !== null) {
        const bytes = v as Uint8Array;
        if (bytes.length === 32) {
          const keyBlob: cryptoFramework.DataBlob = { data: bytes };
          const gen = cryptoFramework.createSymKeyGenerator('AES256');
          return await gen.convertKey(keyBlob);
        }
      }
    }
  } catch (e) {
    const code = (e as BusinessError).code;
    if (code === asset.ErrorCode.NOT_FOUND) {
      hilog.warn(TAG, DOMAIN, 'ApiKeyCrypto 查询主密钥失败(NOT_FOUND %{public}s)，将尝试重新创建', (code ?? '-') + ': ' + String(e));
    } else {
      hilog.warn(TAG, DOMAIN, 'ApiKeyCrypto 查询主密钥失败(%{public}s)，将尝试重新创建', (code ?? '-') + ': ' + String(e));
    }
  }
  // 不存在 → 生成并写入
  try {
    const gen = cryptoFramework.createSymKeyGenerator('AES256');
    const key = await gen.generateSymKey();
    const encoded = key.getEncoded();
    if (encoded.data.length !== 32) {
      return null;
    }
    // 注意：asset.add 不接受 asset.Tag.RETURN_TYPE（query 专用参数），
    // 真机上报 Unsupported tag[asset.Tag.RETURN_TYPE]。只传写入所需字段。
    await asset.add(new Map<asset.Tag, asset.Value>([
      [asset.Tag.ALIAS, new util.TextEncoder().encode(KEY_ALIAS)],
      [asset.Tag.SECRET, encoded.data],
      [asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED]
    ]));
    return key;
  } catch (e) {
    const code = (e as BusinessError).code;
    if (code === asset.ErrorCode.DUPLICATED) {
      // 并发/重复创建：重新查一次取已存在的主密钥，避免降级明文。
      try {
        const rows = await asset.query(masterKeyQuery());
        if (rows.length > 0) {
          const v = rows[0].get(asset.Tag.SECRET);
          if (v !== undefined && v !== null) {
            const bytes = v as Uint8Array;
            if (bytes.length === 32) {
              const keyBlob: cryptoFramework.DataBlob = { data: bytes };
              const gen2 = cryptoFramework.createSymKeyGenerator('AES256');
              return await gen2.convertKey(keyBlob);
            }
          }
        }
      } catch (e2) {
        const code2 = (e2 as BusinessError).code;
        hilog.warn(TAG, DOMAIN, 'ApiKeyCrypto 创建主密钥撞 24000003 后重查失败(%{public}s)，API Key 将降级为明文落库', `${code2 ?? '-'}: ${String(e2)}`);
      }
      // 重查仍取不到 SECRET：不静默返回。必须告警归因，否则按「三条日志消失」判据会被误判为通过。
      hilog.warn(TAG, DOMAIN, 'ApiKeyCrypto 撞 24000003 后重查仍取不到主密钥（SECRET 缺失/长度异常），API Key 将降级为明文落库');
      return null;
    }
    hilog.warn(TAG, DOMAIN, 'ApiKeyCrypto 创建主密钥失败(%{public}s)，API Key 将降级为明文落库', `${code ?? '-'}: ${String(e)}`);
    return null;
  }
}

/** 构造 AES-GCM Cipher 并 init。opMode：0=加密 1=解密 */
async function createCipher(
  opMode: cryptoFramework.CryptoMode,
  key: cryptoFramework.SymKey,
  iv: Uint8Array,
  aad: Uint8Array,
  authTag?: Uint8Array
): Promise<cryptoFramework.Cipher> {
  const cipher = cryptoFramework.createCipher('AES256|GCM|PKCS7');
  const params: cryptoFramework.GcmParamsSpec = {
    iv: { data: iv },
    aad: { data: aad },
    authTag: { data: authTag ?? new Uint8Array(0) },
    algName: 'GcmParamsSpec'
  };
  await cipher.init(opMode, key, params);
  return cipher;
}

/**
 * 加密 API Key。失败策略分两级（见文件头注释）：
 *   - keystore 不可用（缺权限/锁屏 DEVICE_FIRST_UNLOCKED/系统异常）：
 *     降级返回**明文**，hilog.warn 告警，不抛错 —— 不阻断登录与供应商编辑。
 *     设备解锁后再次写入会自动恢复加密。
 *   - keystore 正常但加密过程本身失败：抛错（fail-closed），防止数据损坏。
 * GCM 模式：明文长度 < 16KB 时可一次性 doFinal，返回 data = ciphertext + authTag。
 */
export async function encryptApiKey(plain: string): Promise<string> {
  if (plain.length === 0) {
    return '';
  }
  const key = await getOrCreateMasterKey();
  if (key === null) {
    // keystore 不可用（缺权限/设备锁屏/系统异常）时降级为明文落库并告警。
    // 与 AppStore.setToken 的可用性优先策略对齐：登录/编辑供应商不能被加密阻断，
    // 但必须告警，不能静默退化。设备解锁后再次写入会自动恢复加密。
    hilog.warn(TAG, DOMAIN, 'ApiKeyCrypto keystore 不可用，API Key 降级为明文落库（请检查 SECURITY_ASSET 权限/设备解锁）');
    return plain;
  }
  // IV 必须用密码学安全随机源：GCM 复用同一 (key, IV) 会让 authTag 完全失效，
  // 攻击者可伪造密文。Math.random() 是可预测的 PRNG，绝不可用于 IV。
  // generateRandom(len) 的返回长度可能按块对齐上浮（>12），故显式取前 12 字节。
  const ivRand = await cryptoFramework.createRandom().generateRandom(12);
  const ivRandBytes = new Uint8Array(ivRand.data);
  if (ivRandBytes.length < GCM_IV_LENGTH) {
    throw new Error('随机 IV 生成失败：长度不足');
  }
  const iv = ivRandBytes.slice(0, GCM_IV_LENGTH);
  // GCM AAD：绑定应用域，防止跨表/跨字段替换
  const aad = new util.TextEncoder().encode('ekko-studio-provider-apikey-v1');
  const plainBytes = new util.TextEncoder().encode(plain);

  const cipher = await createCipher(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, iv, aad);
  // GCM 的 doFinal 返回密文 + authTag（无独立 update 输出）
  const out = await cipher.doFinal({ data: plainBytes });
  key.clearMem();

  const combined = out.data;
  return `${API_KEY_CIPHER_PREFIX}${b64Encode(iv)}:${b64Encode(combined)}`;
}

/**
 * 解密 API Key 的结果（Scheme A 三态的数据源）。
 *   - apiKey：内存明文；解密失败时为 ''（与未填同值，状态由 state 区分）。
 *   - state：
 *       'empty'         —— 原始值为空串（真未填）。
 *       'ok'            —— 已填且可解密（含存量明文无前缀，直接原文返回）。
 *       'undecryptable' —— 原始值为非空密文（ekko:v1: 前缀）但解密失败。
 */
export interface DecryptedApiKey {
  apiKey: string;
  state: 'empty' | 'ok' | 'undecryptable';
}

/**
 * 解密 API Key 并携带三态。失败返回 { apiKey: '', state: 'undecryptable' }，不抛错。
 * 兼容存量明文：无前缀的直接返回原文（state='ok'，由调用方决定是否惰性迁移）。
 */
export async function decryptApiKeyWithState(stored: string): Promise<DecryptedApiKey> {
  if (stored.length === 0) {
    return { apiKey: '', state: 'empty' };
  }
  if (!stored.startsWith(API_KEY_CIPHER_PREFIX)) {
    return { apiKey: stored, state: 'ok' }; // 存量明文
  }
  const key = await getOrCreateMasterKey();
  if (key === null) {
    hilog.warn(TAG, DOMAIN, 'ApiKeyCrypto 主密钥不可用，无法解密');
    return { apiKey: '', state: 'undecryptable' };
  }
  const body = stored.substring(API_KEY_CIPHER_PREFIX.length);
  const parts = body.split(':');
  if (parts.length !== 2) {
    return { apiKey: '', state: 'undecryptable' };
  }
  try {
    const iv = b64Decode(parts[0]);
    const combined = b64Decode(parts[1]);
    if (iv.length !== GCM_IV_LENGTH || combined.length < 16) {
      return { apiKey: '', state: 'undecryptable' };
    }
    const ctLen = combined.length - 16;
    const ct = combined.subarray(0, ctLen);
    const tag = combined.subarray(ctLen);
    const aad = new util.TextEncoder().encode('ekko-studio-provider-apikey-v1');
    const cipher = await createCipher(cryptoFramework.CryptoMode.DECRYPT_MODE, key, iv, aad, tag);
    // GCM 解密：authTag 在 init 时传入，doFinal 输入纯密文，输出明文
    const out = await cipher.doFinal({ data: ct });
    key.clearMem();
    const decoder = new util.TextDecoder('utf-8', { fatal: false });
    return { apiKey: decoder.decodeToString(out.data), state: 'ok' };
  } catch (e) {
    const detail = e instanceof Error ? e.message : String(e);
    hilog.warn(TAG, DOMAIN, 'ApiKeyCrypto 解密失败(%{public}s)', `${detail}`);
    return { apiKey: '', state: 'undecryptable' };
  }
}

/**
 * 解密 API Key。失败返回空串（调用方提示重新填写），不抛错。
 * 兼容存量明文：无前缀的直接返回原文（由调用方决定是否惰性迁移）。
 * ⚠ 该方法只返回明文，不区分「真未填」与「解密失败」；需要三态时请用
 *   decryptApiKeyWithState（Scheme A 后所有 Provider 构造点均已切换）。
 */
export async function decryptApiKey(stored: string): Promise<string> {
  const res = await decryptApiKeyWithState(stored);
  return res.apiKey;
}