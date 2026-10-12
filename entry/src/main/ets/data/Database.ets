/**
 * 数据层：relationalStore (SQLite) 封装 + 建表 + 迁移。
 *
 * 对应原版 packages/server 里 better-sqlite3 的角色（表名沿用原版，
 * 便于与 Ekko Studio 服务端共享同一个 .db 文件）。
 */

import relationalStore from '@ohos.data.relationalStore';
import common from '@ohos.app.ability.common';

/** 数据库名与版本 */
const DB_NAME = 'hermes-web-ui.db';
const DB_VERSION = 7;

export class Database {
  private static store: relationalStore.RdbStore | null = null;
  private static initializing: Promise<relationalStore.RdbStore> | null = null;

  static async open(context: common.UIAbilityContext): Promise<relationalStore.RdbStore> {
    if (Database.store !== null) {
      return Database.store;
    }
    if (Database.initializing !== null) {
      return Database.initializing;
    }
    Database.initializing = Database.doOpen(context);
    try {
      Database.store = await Database.initializing;
      return Database.store;
    } finally {
      Database.initializing = null;
    }
  }

  private static async doOpen(context: common.UIAbilityContext): Promise<relationalStore.RdbStore> {
    const config: relationalStore.StoreConfig = {
      name: DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const store = await relationalStore.getRdbStore(context, config);
    await Database.migrate(store);
    return store;
  }

  /** 迁移链：逐版本升，每步都是幂等的 */
  private static async migrate(store: relationalStore.RdbStore): Promise<void> {
    // RdbStore.version 是**属性**，不是方法
    const cur: number = store.version;
    if (cur >= DB_VERSION) {
      return;
    }

    // v1：单聊 + 群聊基础表
    if (cur < 1) {
      // 每个版本块单独一个事务：迁移链本身幂等（IF NOT EXISTS 自愈），
      // 但崩溃窗口内库会停在半迁移态，期间读库路径拿不到一致 schema。
      store.beginTransaction();
      try {
        await store.executeSql(`CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        source TEXT NOT NULL DEFAULT 'api_server',
        category_id INTEGER,
        category_name TEXT,
        workspace TEXT,
        model TEXT,
        provider TEXT,
        channel TEXT,
        pinned INTEGER NOT NULL DEFAULT 0,
        active INTEGER NOT NULL DEFAULT 0,
        message_count INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )`);

      await store.executeSql(`CREATE TABLE IF NOT EXISTS messages (
        id TEXT PRIMARY KEY NOT NULL,
        session_id TEXT NOT NULL,
        run_id TEXT,
        role TEXT NOT NULL,
        content TEXT NOT NULL DEFAULT '',
        blocks TEXT,
        agent_name TEXT,
        model TEXT,
        provider TEXT,
        usage TEXT,
        tool_trace TEXT,
        reasoning TEXT,
        error TEXT,
        timestamp INTEGER NOT NULL,
        FOREIGN KEY (session_id) REFERENCES sessions (id) ON DELETE CASCADE
      )`);
      await store.executeSql('CREATE INDEX IF NOT EXISTS idx_messages_session ON messages (session_id, timestamp)');
      await store.executeSql('CREATE INDEX IF NOT EXISTS idx_messages_ts ON messages (timestamp)');

      await store.executeSql(`CREATE TABLE IF NOT EXISTS categories (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        created_at INTEGER NOT NULL
      )`);

      await store.executeSql(`CREATE TABLE IF NOT EXISTS providers (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        base_url TEXT NOT NULL DEFAULT '',
        api_key TEXT NOT NULL DEFAULT '',
        /* ③ API Key 存储态脱敏：api_key 列优先落 AES-GCM-256 密文（ekko:v1: 前缀），
                   明文只存在于内存 Provider 对象。加解密见 data/ApiKeyCrypto.ets。
                   注意：keystore 不可用时（锁屏等）会降级落明文并告警，见 ApiKeyCrypto 文件头。 */
        api_mode TEXT NOT NULL DEFAULT 'chat_completions',
        models TEXT NOT NULL DEFAULT '[]',
        enabled INTEGER NOT NULL DEFAULT 1,
        builtin INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL
      )`);

      await store.executeSql(`CREATE TABLE IF NOT EXISTS agent_profiles (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        runtime TEXT NOT NULL,
        provider TEXT NOT NULL DEFAULT '',
        model TEXT NOT NULL DEFAULT '',
        api_mode TEXT NOT NULL DEFAULT 'chat_completions',
        system_prompt TEXT NOT NULL DEFAULT '',
        reasoning_effort TEXT NOT NULL DEFAULT '',
        tools_enabled INTEGER NOT NULL DEFAULT 1,
        enabled INTEGER NOT NULL DEFAULT 1,
        updated_at INTEGER NOT NULL
      )`);
      store.commit();
    } catch (e) {
      store.rollBack();
      // P2-5：保留原始错误信息，否则开发者看不到真正的 SQL 错误
      const detail = e instanceof Error ? e.message : String(e);
      throw new Error(`迁移 v1 失败，已回滚: ${detail}`);
    }
  }

    // v2：群聊房间与 Agent、执行队列
    if (cur < 2) {
      store.beginTransaction();
      try {
        await store.executeSql(`CREATE TABLE IF NOT EXISTS gc_rooms (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        invite_code TEXT,
        owner_member_id TEXT,
        summary_profile TEXT NOT NULL DEFAULT '',
        summary_provider TEXT NOT NULL DEFAULT '',
        summary_model TEXT NOT NULL DEFAULT '',
        summary_api_mode TEXT NOT NULL DEFAULT 'chat_completions',
        summary_every_turns INTEGER NOT NULL DEFAULT 0,
        total_tokens INTEGER NOT NULL DEFAULT 0,
        workspace TEXT NOT NULL DEFAULT '',
        agent_handoff_enabled INTEGER NOT NULL DEFAULT 0,
        agent_handoff_max_depth INTEGER,
        agent_handoff_unlimited INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL DEFAULT 0,
        last_active_at INTEGER NOT NULL DEFAULT 0
      )`);

      await store.executeSql(`CREATE TABLE IF NOT EXISTS gc_room_agents (
        id TEXT PRIMARY KEY NOT NULL,
        room_id TEXT NOT NULL,
        agent_id TEXT NOT NULL,
        agent TEXT NOT NULL,
        agent_mode TEXT NOT NULL DEFAULT 'scoped',
        profile TEXT NOT NULL DEFAULT '',
        provider TEXT NOT NULL DEFAULT '',
        model TEXT NOT NULL DEFAULT '',
        api_mode TEXT NOT NULL DEFAULT 'chat_completions',
        agent_preset TEXT,
        reasoning_effort TEXT NOT NULL DEFAULT '',
        name TEXT NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        avatar TEXT NOT NULL DEFAULT '',
        invited INTEGER NOT NULL DEFAULT 0,
        executor_type TEXT NOT NULL DEFAULT 'server',
        remote_origin TEXT,
        connection_status TEXT NOT NULL DEFAULT 'online',
        owner_member_id TEXT,
        connector_id TEXT,
        removed_at INTEGER NOT NULL DEFAULT 0
      )`);
      // @ 提及按 agent_id 查，故单独建索引
      await store.executeSql('CREATE INDEX IF NOT EXISTS idx_gc_room_agents_agent ON gc_room_agents (room_id, agent_id)');
      await store.executeSql('CREATE INDEX IF NOT EXISTS idx_gc_room_agents_name ON gc_room_agents (room_id, name)');

      await store.executeSql(`CREATE TABLE IF NOT EXISTS gc_messages (
        id TEXT PRIMARY KEY NOT NULL,
        room_id TEXT NOT NULL,
        sender_name TEXT NOT NULL,
        sender_kind TEXT NOT NULL DEFAULT 'agent',
        agent_id TEXT,
        role TEXT NOT NULL DEFAULT 'assistant',
        content TEXT NOT NULL DEFAULT '',
        mentions TEXT,
        usage TEXT,
        tool_trace TEXT,
        timestamp INTEGER NOT NULL
      )`);
      await store.executeSql('CREATE INDEX IF NOT EXISTS idx_gc_messages_room ON gc_messages (room_id, timestamp)');

      await store.executeSql(`CREATE TABLE IF NOT EXISTS gc_execution_queue (
        id TEXT PRIMARY KEY NOT NULL,
        room_id TEXT NOT NULL,
        target_agent_id TEXT NOT NULL,
        target_agent_name TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL DEFAULT 'queued',
        error TEXT,
        created_at INTEGER NOT NULL,
        started_at INTEGER,
        finished_at INTEGER
      )`);
      await store.executeSql('CREATE INDEX IF NOT EXISTS idx_gc_queue_room ON gc_execution_queue (room_id, status)');
      store.commit();
    } catch (e) {
      store.rollBack();
      // P2-5：保留原始错误信息，否则开发者看不到真正的 SQL 错误
      const detail = e instanceof Error ? e.message : String(e);
      throw new Error(`迁移 v2 失败，已回滚: ${detail}`);
    }
  }

    // v3：会话归档分类补列 + 远端同步游标
    if (cur < 3) {
      store.beginTransaction();
      try {
        await addColumnIfMissing(store, 'sessions', 'remote_synced', 'INTEGER NOT NULL DEFAULT 0');
        await addColumnIfMissing(store, 'sessions', 'last_message_preview', "TEXT NOT NULL DEFAULT ''");
        store.commit();
      } catch (e) {
        store.rollBack();
        // P2-5：保留原始错误信息，否则开发者看不到真正的 SQL 错误
        const detail = e instanceof Error ? e.message : String(e);
        throw new Error(`迁移 v3 失败，已回滚: ${detail}`);
      }
    }

    // v4：附件、会话分享、归档
    if (cur < 4) {
      store.beginTransaction();
      try {
      await store.executeSql(`CREATE TABLE IF NOT EXISTS attachments (
        id TEXT PRIMARY KEY NOT NULL,
        session_id TEXT NOT NULL DEFAULT '',
        room_id TEXT NOT NULL DEFAULT '',
        message_id TEXT NOT NULL DEFAULT '',
        name TEXT NOT NULL,
        path TEXT NOT NULL,
        media_type TEXT NOT NULL DEFAULT '',
        size INTEGER NOT NULL DEFAULT 0,
        kind TEXT NOT NULL DEFAULT 'file',
        created_at INTEGER NOT NULL
      )`);
      await store.executeSql('CREATE INDEX IF NOT EXISTS idx_attachments_session ON attachments (session_id)');
      await store.executeSql('CREATE INDEX IF NOT EXISTS idx_attachments_room ON attachments (room_id)');

      await store.executeSql(`CREATE TABLE IF NOT EXISTS session_shares (
        token TEXT PRIMARY KEY NOT NULL,
        session_id TEXT NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        kind TEXT NOT NULL DEFAULT 'session',
        expires_at INTEGER NOT NULL DEFAULT 0,
        view_count INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )`);
      await store.executeSql('CREATE INDEX IF NOT EXISTS idx_shares_session ON session_shares (session_id)');

      await store.executeSql(`CREATE TABLE IF NOT EXISTS session_archives (
        id TEXT PRIMARY KEY NOT NULL,
        session_id TEXT NOT NULL,
        label TEXT NOT NULL DEFAULT '',
        note TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL
      )`);
      await addColumnIfMissing(store, 'sessions', 'archived', 'INTEGER NOT NULL DEFAULT 0');
      store.commit();
    } catch (e) {
      store.rollBack();
      // P2-5：保留原始错误信息，否则开发者看不到真正的 SQL 错误
      const detail = e instanceof Error ? e.message : String(e);
      throw new Error(`迁移 v4 失败，已回滚: ${detail}`);
    }
  }

    // v5：Skills / 插件 / MCP
    if (cur < 5) {
      store.beginTransaction();
      try {
      await store.executeSql(`CREATE TABLE IF NOT EXISTS skills (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        instructions TEXT NOT NULL DEFAULT '',
        source TEXT NOT NULL DEFAULT 'local',
        enabled INTEGER NOT NULL DEFAULT 1,
        usage_count INTEGER NOT NULL DEFAULT 0,
        last_used_at INTEGER NOT NULL DEFAULT 0,
        builtin INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL
      )`);

      await store.executeSql(`CREATE TABLE IF NOT EXISTS plugins (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        version TEXT NOT NULL DEFAULT '',
        description TEXT NOT NULL DEFAULT '',
        enabled INTEGER NOT NULL DEFAULT 1,
        config TEXT NOT NULL DEFAULT '{}',
        installed_at INTEGER NOT NULL
      )`);

      await store.executeSql(`CREATE TABLE IF NOT EXISTS mcp_servers (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        transport TEXT NOT NULL DEFAULT 'stdio',
        command TEXT NOT NULL DEFAULT '',
        args TEXT NOT NULL DEFAULT '[]',
        url TEXT NOT NULL DEFAULT '',
        env TEXT NOT NULL DEFAULT '{}',
        enabled INTEGER NOT NULL DEFAULT 1,
        builtin INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL
      )`);
      store.commit();
    } catch (e) {
      store.rollBack();
      // P2-5：保留原始错误信息，否则开发者看不到真正的 SQL 错误
      const detail = e instanceof Error ? e.message : String(e);
      throw new Error(`迁移 v5 失败，已回滚: ${detail}`);
    }
  }

    // v6：定时任务、看板、记忆、用量、日志、主题、布局偏好
    if (cur < 6) {
      store.beginTransaction();
      try {
      await store.executeSql(`CREATE TABLE IF NOT EXISTS jobs (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        cron TEXT NOT NULL DEFAULT '',
        session_id TEXT NOT NULL DEFAULT '',
        room_id TEXT NOT NULL DEFAULT '',
        agent_id TEXT NOT NULL DEFAULT '',
        prompt TEXT NOT NULL DEFAULT '',
        enabled INTEGER NOT NULL DEFAULT 1,
        last_run_at INTEGER NOT NULL DEFAULT 0,
        last_status TEXT NOT NULL DEFAULT '',
        next_run_at INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )`);

      await store.executeSql(`CREATE TABLE IF NOT EXISTS kanban_cards (
        id TEXT PRIMARY KEY NOT NULL,
        column_id TEXT NOT NULL,
        title TEXT NOT NULL,
        body TEXT NOT NULL DEFAULT '',
        tag TEXT NOT NULL DEFAULT '',
        priority INTEGER NOT NULL DEFAULT 1,
        position INTEGER NOT NULL DEFAULT 0,
        session_id TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )`);
      await store.executeSql('CREATE INDEX IF NOT EXISTS idx_kanban_column ON kanban_cards (column_id, position)');

      await store.executeSql(`CREATE TABLE IF NOT EXISTS kanban_columns (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        position INTEGER NOT NULL DEFAULT 0,
        wip_limit INTEGER NOT NULL DEFAULT 0
      )`);

      await store.executeSql(`CREATE TABLE IF NOT EXISTS memories (
        id TEXT PRIMARY KEY NOT NULL,
        scope TEXT NOT NULL DEFAULT 'global',
        scope_id TEXT NOT NULL DEFAULT '',
        kind TEXT NOT NULL DEFAULT 'note',
        content TEXT NOT NULL,
        pinned INTEGER NOT NULL DEFAULT 0,
        hit_count INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )`);
      await store.executeSql('CREATE INDEX IF NOT EXISTS idx_memories_scope ON memories (scope, scope_id)');

      await store.executeSql(`CREATE TABLE IF NOT EXISTS usage_records (
        id TEXT PRIMARY KEY NOT NULL,
        session_id TEXT NOT NULL DEFAULT '',
        room_id TEXT NOT NULL DEFAULT '',
        agent_id TEXT NOT NULL DEFAULT '',
        provider TEXT NOT NULL DEFAULT '',
        model TEXT NOT NULL DEFAULT '',
        input_tokens INTEGER NOT NULL DEFAULT 0,
        output_tokens INTEGER NOT NULL DEFAULT 0,
        cost_usd REAL NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )`);
      await store.executeSql('CREATE INDEX IF NOT EXISTS idx_usage_time ON usage_records (created_at)');

      await store.executeSql(`CREATE TABLE IF NOT EXISTS app_logs (
        id TEXT PRIMARY KEY NOT NULL,
        level TEXT NOT NULL DEFAULT 'info',
        scope TEXT NOT NULL DEFAULT '',
        message TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL
      )`);
      await store.executeSql('CREATE INDEX IF NOT EXISTS idx_logs_time ON app_logs (created_at)');

      // 键值偏好：主题、布局、窗口形态等。放DB 而非 preferences，
      // 是因为它们要能被多页面原子读写并随会话库一起迁移。
      await store.executeSql(`CREATE TABLE IF NOT EXISTS prefs (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
      )`);
      store.commit();
    } catch (e) {
      store.rollBack();
      // P2-5：保留原始错误信息，否则开发者看不到真正的 SQL 错误
      const detail = e instanceof Error ? e.message : String(e);
      throw new Error(`迁移 v6 失败，已回滚: ${detail}`);
    }
  }

    // v7：@all 开关。
    // 此前 gc_rooms 没有这一列，RoomInfo.canMentionAll 恒为 undefined，
    // 导致 resolveMentions 里的 @all 分支永远进不去（界面有入口但无响应）。
    if (cur < 7) {
      store.beginTransaction();
      try {
        await addColumnIfMissing(store, 'gc_rooms', 'can_mention_all', 'INTEGER NOT NULL DEFAULT 1');
        store.commit();
      } catch (e) {
        store.rollBack();
        // P2-5：保留原始错误信息，否则开发者看不到真正的 SQL 错误
        const detail = e instanceof Error ? e.message : String(e);
        throw new Error(`迁移 v7 失败，已回滚: ${detail}`);
      }
    }

    // meta 表此前只在 writeMeta 里运行时 CREATE TABLE，既不版本化也没人调。
    // 放进迁移链建表并写 app 版本号，排查本地库问题时能直接读出库是哪个版本建的。
    // 注：这块的执行条件不是「需要迁移」，而是「meta 表可能还没建」——
    // 老库若版本号已是当前值，上面的版本块会全部跳过，meta 表就永远不会被创建。
    // 所以这里独立判断：表不存在才建（IF NOT EXISTS 本身幂等，这里只是让意图明确）。
    const metaExists = await queryOne(store, "SELECT name FROM sqlite_master WHERE type='table' AND name='meta'");
    if (metaExists === null) {
      store.beginTransaction();
      try {
        await store.executeSql(
          'CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)');
        await store.executeSql(
          `INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', ?)`,
          [`${DB_VERSION}`]);
        store.commit();
      } catch (e) {
        store.rollBack();
        throw new Error('写 meta 失败，已回滚');
      }
    }

    store.version = DB_VERSION;
  }
  static async close(): Promise<void> {
    if (Database.store !== null) {
      try {
        await Database.store.close();
      } catch (e) {
        // 关闭失败不影响运行
      }
      Database.store = null;
    }
  }
}

/**
 * 加列：SQLite 不支持 IF NOT EXISTS 的 ADD COLUMN，
 * 先查 PRAGMA table_info，有则跳过（保证迁移幂等）。
 */
async function addColumnIfMissing(
  store: relationalStore.RdbStore,
  table: string,
  column: string,
  ddl: string
): Promise<void> {
  const rs = await store.querySql(`PRAGMA table_info(${table})`);
  let exists = false;
  try {
    if (rs.goToFirstRow()) {
      const idx = rs.getColumnIndex('name');
      if (idx >= 0) {
        const rowCount = rs.rowCount;
        for (let i = 0; i < rowCount; i++) {
          rs.goToRow(i);
          if (rs.getString(idx) === column) {
            exists = true;
            break;
          }
        }
      }
    }
  } finally {
    // goToFirstRow/getColumnIndex/getString 抛异常时 ResultSet 也会泄漏，
    // 与 queryToObjects 的 finally 关闭对齐。
    rs.close();
  }
  if (!exists) {
    await store.executeSql(`ALTER TABLE ${table} ADD COLUMN ${column} ${ddl}`);
  }
}

/** 把 ResultSet 逐行取成对象数组，并关闭 rs。 */
export async function queryToObjects(
  store: relationalStore.RdbStore,
  sql: string,
  args: Array<relationalStore.ValueType> = []
): Promise<Record<string, relationalStore.ValueType>[]> {
  const rs = await store.querySql(sql, args);
  const out: Record<string, relationalStore.ValueType>[] = [];
  try {
    if (rs.goToFirstRow()) {
      const count = rs.rowCount;
      const cols = rs.columnCount;
      for (let i = 0; i < count; i++) {
        rs.goToRow(i);
        const obj: Record<string, relationalStore.ValueType> = {};
        for (let c = 0; c < cols; c++) {
          const name = rs.getColumnName(c);
          obj[name] = rs.getValue(c);
        }
        out.push(obj);
      }
    }
  } finally {
    rs.close();
  }
  return out;
}

export async function queryOne(
  store: relationalStore.RdbStore,
  sql: string,
  args: Array<relationalStore.ValueType> = []
): Promise<Record<string, relationalStore.ValueType> | null> {
  const rows = await queryToObjects(store, sql, args);
  return rows.length > 0 ? rows[0] : null;
}

export function str(row: Record<string, relationalStore.ValueType> | null, key: string, fallback: string = ''): string {
  if (row === null) {
    return fallback;
  }
  const v = row[key];
  if (typeof v === 'string') {
    return v;
  }
  if (typeof v === 'number') {
    return `${v}`;
  }
  return fallback;
}

export function num(row: Record<string, relationalStore.ValueType> | null, key: string, fallback: number = 0): number {
  if (row === null) {
    return fallback;
  }
  const v = row[key];
  if (typeof v === 'number' && isFinite(v)) {
    return v;
  }
  if (typeof v === 'string') {
    const n = Number(v);
    return isFinite(n) ? n : fallback;
  }
  return fallback;
}

export function bool(row: Record<string, relationalStore.ValueType> | null, key: string): boolean {
  return num(row, key, 0) !== 0;
}

// writeMeta/readMeta 已删除：全工程无调用方（meta 表已由迁移链统一建表并写
// schema_version，见 migrate() 内 meta 块），保留只会留一个重复的运行时 CREATE TABLE。

