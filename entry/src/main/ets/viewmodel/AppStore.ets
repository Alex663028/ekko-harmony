/**
 * 全局应用状态：对应原版 Pinia stores（stores/account.ts + stores/hermes/*）。
 * 用 AppStorage 做跨页共享，页面用 @StorageLink 订阅。
 */

import common from '@ohos.app.ability.common';
import relationalStore from '@ohos.data.relationalStore';
import preferences from '@ohos.data.preferences';
import util from '@ohos.util';
import hilog from '@ohos.hilog';
import asset from '@ohos.security.asset';
import { BusinessError } from '@kit.BasicServicesKit';
import { Provider, AgentProfile, SessionSummary, RoomInfo } from '../model/Types';
import { Database } from '../data/Database';
import {
  ProviderRepo, AgentProfileRepo, SessionRepo, RoomRepo, newId
} from '../data/Repos';
import { NetConfig, errorMessage } from '../net/Http';
import { AgentOrchestrator, newEmptyHooks } from '../net/Orchestrator';

const PREFS = 'ekko_prefs';

/** AppStorage 键名集中管理，避免各处硬编码字符串对不上 */
export interface StoreKeys {
  SERVER_URL: string;
  USER_NAME: string;
  USER_ROLE: string;
  THEME_DARK: string;
  PROVIDERS: string;
  AGENT_PROFILES: string;
  ACTIVE_SESSION: string;
  ACTIVE_ROOM: string;
  ONBOARDED: string;
  CHAT_VIEW: string;
  DATA_SOURCE: string;
  TOKEN: string;
}

export const K: StoreKeys = {
  SERVER_URL: 'serverUrl',
  USER_NAME: 'userName',
  USER_ROLE: 'userRole',
  THEME_DARK: 'themeDark',
  PROVIDERS: 'providers',
  AGENT_PROFILES: 'agentProfiles',
  ACTIVE_SESSION: 'activeSessionId',
  ACTIVE_ROOM: 'activeRoomId',
  ONBOARDED: 'onboarded',
  CHAT_VIEW: 'chatView',
  /** 数据源：'local'（默认，数据落手机）| 'server'（读 PC 上的 Ekko Studio） */
  DATA_SOURCE: 'dataSource',
  /** 服务端登录令牌（持久化，重启后仍可用） */
  TOKEN: 'authToken'
};

export class AppStore {
  private static ctx: common.UIAbilityContext | null = null;
  private static store: relationalStore.RdbStore | null = null;
  private static prefs: preferences.Preferences | null = null;

  static db(): relationalStore.RdbStore {
    if (AppStore.store === null) {
      throw new Error('数据库未初始化');
    }
    return AppStore.store;
  }

  /**
   * Ability 上下文。给需要自己开 preferences / relationalStore 的调用方用
   * （例如登录页读联调凭据）。init 之后才有值。
   */
  static context(): common.UIAbilityContext {
    if (AppStore.ctx === null) {
      throw new Error('AppStore 未初始化');
    }
    return AppStore.ctx;
  }

  static async init(context: common.UIAbilityContext): Promise<void> {
    AppStore.ctx = context;
    AppStore.store = await Database.open(context);
    AppStore.prefs = await preferences.getPreferences(context, { name: PREFS });

    const savedUrl = (await AppStore.prefs.get(K.SERVER_URL, 'http://127.0.0.1:8748')) as string;
    NetConfig.setBaseUrl(savedUrl);
    AppStorage.setOrCreate<string>(K.SERVER_URL, savedUrl);

    const onboarded = (await AppStore.prefs.get(K.ONBOARDED, false)) as boolean;
    AppStorage.setOrCreate<boolean>(K.ONBOARDED, onboarded);

    const dark = (await AppStore.prefs.get(K.THEME_DARK, false)) as boolean;
    AppStorage.setOrCreate<boolean>(K.THEME_DARK, dark);

    const userName = (await AppStore.prefs.get(K.USER_NAME, '')) as string;
    AppStorage.setOrCreate<string>(K.USER_NAME, userName);

    // 数据源：默认本地。登录页选「连接服务端」时会被改写成 'server'。
    const ds = (await AppStore.prefs.get(K.DATA_SOURCE, 'local')) as string;
    AppStorage.setOrCreate<string>(K.DATA_SOURCE, ds);

    // 恢复上次的登录令牌。服务端模式下没它寸步难行（所有请求都要带）。
    // 走 keystore 读（P1-5）；读不到就退回兼容旧的明文 preferences。
    await AppStore.restoreToken();

    // D-R35-1：**无条件**清理旧明文令牌残留，不能只在 keystore 为空时才清。
    // 历史版本存在「keystore 已有令牌 + prefs 仍残留明文」的合法状态（旧版降级写明文路径），
    // 若清理逻辑包在 `if (NetConfig.getToken().length === 0)` 里，keystore 一旦读到令牌，
    // 明文就永远不会被清 → 明文密钥永久留盘（真机 T6 复现）。
    // 因此这里不依赖 NetConfig 是否有令牌：只要 prefs 里还有明文就删。
    const legacyTk = (await AppStore.prefs.get(K.TOKEN, '')) as string;
    if (legacyTk.length > 0) {
      // keystore 没有令牌（旧版登录后从未迁移成功）时才回填；
      // keystore 已有令牌则直接丢弃明文，无需再写一遍。
      if (NetConfig.getToken().length === 0) {
        NetConfig.setToken(legacyTk);
        // 迁移到 keystore：下次起就走加密存储
        await AppStore.setToken(legacyTk);
      }
      // R35 G4 / D-R35-1：无论是否回填，都必须清除明文残留，避免明文密钥永久留盘
      await AppStore.prefs.delete(K.TOKEN);
      await AppStore.prefs.flush();
    }

    await AppStore.reloadProviders();
    await AppStore.reloadAgents();
    await AppStore.ensureBuiltinProviders();
  }

  /**
   * 当前是否处于「服务端模式」。
   *
   * 这是整套远程通路的开关：所有 Repo 的读写方法都先问它，
   * 返回 true 就走 StudioApi 读 PC 上的 Ekko Studio，否则走本地 SQLite。
   *
   * 用 AppStorage 而不是成员变量 —— 页面和 Repo 都能直接读到，
   * 且改一次全局即时生效，不需要逐层传参。
   */
  static isServerMode(): boolean {
    return (AppStorage.get<string>(K.DATA_SOURCE) ?? 'local') === 'server';
  }

  /** 切换数据源。会持久化，重启后保持。 */
  static async setDataSource(src: string): Promise<void> {
    const v = src === 'server' ? 'server' : 'local';
    AppStorage.setOrCreate<string>(K.DATA_SOURCE, v);
    if (AppStore.prefs !== null) {
      await AppStore.prefs.put(K.DATA_SOURCE, v);
      await AppStore.prefs.flush();
    }
  }

  /**
   * 保存登录令牌。
   *
   * 必须持久化：服务端模式下所有请求都要带它，
   * 只放内存的话 App 一重启就变成「未登录」，用户得反复登录。
   *
   * 🔐 持久化走系统 keystore（@ohos.security.asset），不落明文 preferences。
   *   Asset 由系统级加密存储，root 设备也无法直接读出内容；明文 preferences
   *   则可被工具化访问（_test 里就有读 preferences 的脚本）。
   *   失败时退回明文并告警 —— 可用性优先，但不能静默退化。
   */
  static async setToken(t: string): Promise<void> {
    NetConfig.setToken(t);
    try {
      const secret: Uint8Array = new util.TextEncoder().encode(t);
      // asset.query 无匹配资产时抛 24000002（NOT_FOUND）而非返回空数组，
      // 首次写入必须捕获该错误，否则会误入 update 分支报 not found。
      let existing: Array<Map<asset.Tag, asset.Value>> = [];
      try {
        existing = await asset.query(AppStore.tokenSecretQuery());
      } catch (e) {
        existing = [];
      }
      if (existing.length === 0) {
        // 注意：asset.add/update 不接受 asset.Tag.RETURN_TYPE（query 专用参数），
        // 真机上报 Unsupported tag[asset.Tag.RETURN_TYPE]。只传写入所需字段。
        await asset.add(new Map<asset.Tag, asset.Value>([
          [asset.Tag.ALIAS, AppStore.tokenAliasBytes()],
          [asset.Tag.SECRET, secret],
          [asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED]
        ]));
      } else {
        const q = new Map<asset.Tag, asset.Value>([[asset.Tag.ALIAS, AppStore.tokenAliasBytes()]]);
        await asset.update(q, new Map<asset.Tag, asset.Value>([
          [asset.Tag.SECRET, secret]
        ]));
      }
      return;
    } catch (e) {
      const code = (e as BusinessError).code;
      hilog.warn(0xE000, 'EkkoStore', 'keystore 写令牌失败(%{public}s)，退回明文 preferences', `${code ?? '-'}: ${String(e)}`);
    }
    if (AppStore.prefs !== null) {
      await AppStore.prefs.put(K.TOKEN, t);
      await AppStore.prefs.flush();
    }
  }

  /** 退出登录：清令牌并切回本地数据源 */
  static async clearToken(): Promise<void> {
    NetConfig.clear();
    try {
      await asset.remove(AppStore.tokenQuery());
    } catch (e) {
      hilog.warn(0xE000, 'EkkoStore', 'keystore 清令牌失败: %{public}s', `${errorMessage(e)}`);
    }
    if (AppStore.prefs !== null) {
      await AppStore.prefs.put(K.TOKEN, '');
      await AppStore.prefs.flush();
    }
    await AppStore.setDataSource('local');
  }

  /** 当前登录令牌（服务端模式下所有请求都要带） */
  static token(): string {
    return NetConfig.getToken();
  }

  /**
   * 从 keystore 读令牌。AppStore.init 在异步流程里调，
   * 拿到就恢复进 NetConfig；拿不到（首装/被清）就留空。
   */
  static async restoreToken(): Promise<void> {
    // 内层 catch：首装/被清时 asset.query 抛 24000002（NOT_FOUND）是正常态，
    // 静默返回即可，不能落冷启动假告警。仅非 NOT_FOUND 错误才告警。
    let rows: Array<Map<asset.Tag, asset.Value>> = [];
    try {
      rows = await asset.query(AppStore.tokenSecretQuery());
    } catch (e) {
      const code = (e as BusinessError).code;
      if (code !== asset.ErrorCode.NOT_FOUND) {
        hilog.warn(0xE000, 'EkkoStore', 'keystore 读令牌失败: %{public}s', `${code ?? '-'}: ${String(e)}`);
      }
      return;
    }
    if (rows.length === 0) {
      return;
    }
    const v = rows[0].get(asset.Tag.SECRET);
    if (v === undefined || v === null) {
      return;
    }
    const bytes = v as Uint8Array;
    const decoder = new util.TextDecoder('utf-8', { fatal: false });
    const tk = decoder.decodeToString(bytes);
    if (tk.length > 0) {
      NetConfig.setToken(tk);
    }
  }

  private static TOKEN_ALIAS = 'ekko.studio.authToken';

  /** asset 的 Value 类型是 boolean | number | Uint8Array，ALIAS 需编码为字节 */
  private static tokenAliasBytes(): Uint8Array {
    return new util.TextEncoder().encode(AppStore.TOKEN_ALIAS);
  }

  private static tokenQuery(): Map<asset.Tag, asset.Value> {
    return new Map<asset.Tag, asset.Value>([[asset.Tag.ALIAS, AppStore.tokenAliasBytes()]]);
  }

  /**
   * 读令牌专用查询：与 tokenQuery() 的区别是要求返回 SECRET 明文。
   * asset 服务端对不带 RETURN_TYPE = ReturnType.ALL 的 query 会主动剥掉 SECRET
   * （有行无密文），导致 restoreToken/setToken 永远读不回令牌（seq22-R2 根因）。
   * 注意：本方法**不能**用于 asset.remove —— remove 不接受 RETURN_TYPE tag
   * （operation_remove.rs 的 valid_tags 不含该属性），clearToken 必须继续用 tokenQuery()。
   */
  private static tokenSecretQuery(): Map<asset.Tag, asset.Value> {
    return new Map<asset.Tag, asset.Value>([
      [asset.Tag.ALIAS, AppStore.tokenAliasBytes()],
      [asset.Tag.RETURN_TYPE, asset.ReturnType.ALL]
    ]);
  }

  static requireToken(): string {
    const t = NetConfig.getToken();
    if (t.length === 0) {
      throw new Error('服务端模式下未登录，请先退出重新登录');
    }
    return t;
  }

  static async setServerUrl(url: string): Promise<void> {
    NetConfig.setBaseUrl(url);
    AppStorage.setOrCreate<string>(K.SERVER_URL, url);
    if (AppStore.prefs !== null) {
      await AppStore.prefs.put(K.SERVER_URL, url);
      await AppStore.prefs.flush();
    }
  }

  static async setUser(name: string, role: string): Promise<void> {
    AppStorage.setOrCreate<string>(K.USER_NAME, name);
    AppStorage.setOrCreate<string>(K.USER_ROLE, role);
    if (AppStore.prefs !== null) {
      await AppStore.prefs.put(K.USER_NAME, name);
      await AppStore.prefs.flush();
    }
  }

  static async setDark(dark: boolean): Promise<void> {
    AppStorage.setOrCreate<boolean>(K.THEME_DARK, dark);
    if (AppStore.prefs !== null) {
      await AppStore.prefs.put(K.THEME_DARK, dark);
      await AppStore.prefs.flush();
    }
  }

  static async reloadProviders(): Promise<void> {
    const list = await ProviderRepo.list(AppStore.db());
    AppStorage.setOrCreate<Provider[]>(K.PROVIDERS, list);
  }

  static async reloadAgents(): Promise<void> {
    const list = await AgentProfileRepo.list(AppStore.db());
    AppStorage.setOrCreate<AgentProfile[]>(K.AGENT_PROFILES, list);
  }

  static providers(): Provider[] {
    return AppStorage.get<Provider[]>(K.PROVIDERS) ?? [];
  }

  static agents(): AgentProfile[] {
    return AppStorage.get<AgentProfile[]>(K.AGENT_PROFILES) ?? [];
  }

  static enabledProviders(): Provider[] {
    // Scheme A：undecryptable（有密文但解密失败）不算可用 ——
    // 它没有明文 key 可发请求，用户需要重新填写。仅 'ok' 且非空才算可用。
    return AppStore.providers().filter((p) =>
      p.enabled && p.apiKeyState === 'ok' && p.apiKey.trim().length > 0);
  }

  /** 首次启动塞一个OpenAI 兼容的默认供应商，省得用户面对空列表 */
  private static async ensureBuiltinProviders(): Promise<void> {
    const now = Date.now();
    const seeds: Provider[] = [
      {
        id: 'builtin-openai',
        name: 'OpenAI',
        baseUrl: 'https://api.openai.com/v1',
        apiKey: '',
        apiKeyState: 'empty',
        apiMode: 'chat_completions',
        models: ['gpt-4o', 'gpt-4o-mini', 'o3-mini'],
        enabled: true,
        builtin: true,
        updatedAt: now
      },
      {
        id: 'builtin-deepseek',
        name: 'DeepSeek',
        baseUrl: 'https://api.deepseek.com/v1',
        apiKey: '',
        apiKeyState: 'empty',
        apiMode: 'chat_completions',
        models: ['deepseek-chat', 'deepseek-reasoner'],
        enabled: true,
        builtin: true,
        updatedAt: now
      },
      {
        id: 'builtin-anthropic',
        name: 'Claude',
        baseUrl: 'https://api.anthropic.com',
        apiKey: '',
        apiKeyState: 'empty',
        apiMode: 'anthropic',
        models: ['claude-sonnet-4-5', 'claude-opus-4-1'],
        enabled: true,
        builtin: true,
        updatedAt: now
      },
      {
        id: 'builtin-longcat',
        name: 'LongCat (本机在用)',
        baseUrl: 'https://api.longcat.chat/openai/v1',
        apiKey: '',
        apiKeyState: 'empty',
        apiMode: 'chat_completions',
        models: ['LongCat-Flash-Chat'],
        enabled: true,
        builtin: true,
        updatedAt: now
      }
    ];
    const existing = AppStore.providers();
    for (const s of seeds) {
      if (!existing.some((p) => p.id === s.id)) {
        // 必须 await：不等待 upsert 完成就 reloadProviders 会读到旧列表
        await ProviderRepo.upsert(AppStore.db(), s, now);
      }
    }
    await AppStore.reloadProviders();
  }

  /**
   * 建默认 Agent。
   *
   * preferredProviderId：优先挂到指定供应商。登录页会把用户刚填 key 的那个
   * 供应商 id 传进来 —— 否则这里会取 enabledProviders() 的第一个（同样是
   * 按 name 字母序，可能是 Claude），用户填的 key 就用不上了。
   */
  static async ensureDefaultAgent(preferredProviderId?: string): Promise<AgentProfile> {
    const agents = AppStore.agents();
    if (agents.length > 0) {
      return agents[0];
    }
    const enabled = AppStore.enabledProviders();
    const all = AppStore.providers();
    let p: Provider | undefined = undefined;
    if (preferredProviderId !== undefined && preferredProviderId.length > 0) {
      for (const it of all) {
        if (it.id === preferredProviderId) {
          p = it;
          break;
        }
      }
    }
    if (p === undefined) {
      p = enabled.length > 0 ? enabled[0] : all[0];
    }
    const a: AgentProfile = {
      id: newId(Date.now()),
      name: '通用助手',
      runtime: 'ekko',
      provider: p !== undefined ? p.id : '',
      model: p !== undefined && p.models.length > 0 ? p.models[0] : '',
      apiMode: p !== undefined ? p.apiMode : 'chat_completions',
      systemPrompt: '你是一个简洁、专业的中文 AI 助手。回答直接给结论，不说废话。',
      reasoningEffort: '',
      toolsEnabled: false,
      enabled: true,
      updatedAt: Date.now()
    };
    await AgentProfileRepo.upsert(AppStore.db(), a, Date.now());
    await AppStore.reloadAgents();
    return a;
  }

  static setActiveSession(id: string): void {
    AppStorage.setOrCreate<string>(K.ACTIVE_SESSION, id);
  }

  static setActiveRoom(id: string): void {
    AppStorage.setOrCreate<string>(K.ACTIVE_ROOM, id);
  }

  static setChatView(view: string): void {
    AppStorage.setOrCreate<string>(K.CHAT_VIEW, view);
  }

  /** 全部清空（设置页的"清数据"） */
  static async wipeAll(): Promise<void> {
    await SessionRepo.deleteAll(AppStore.db());
    // 必须重置为 string 空串：activeSessionId 在 EntryAbility 里是按 string
    // 初始化的，塞数组会造成 AppStorage 同键混装类型，订阅方行为随时序漂移。
    AppStorage.setOrCreate<string>(K.ACTIVE_SESSION, '');
    AgentOrchestrator.setHooks(newEmptyHooks());
  }

  static async close(): Promise<void> {
    await Database.close();
  }
}