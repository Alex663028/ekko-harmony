/**
 * HTTP 客户端：对应原版 packages/client/src/api/client.ts 的 request()。
 *
 * ArkTS 要点：
 *  - 动态头不能用 Record 下标写入 → 用显式字段逐个判断
 *  - 响应体是 string|ArrayBuffer → 先判断类型再转
 *  - 自定义异常不能直接 new Error 带自定义字段 → 定义自己的 error class
 */

import http from '@ohos.net.http';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 响应头：HTTP 只用到这几个键，用具名字段替代动态下标 */
export interface ResponseHeaders {
  contentType: string;
  etag: string;
}

export interface HttpResult {
  code: number;
  body: string;
  headers: ResponseHeaders;
}

export interface RequestOptions {
  method: string;
  path: string;
  body: string;
  token: string;
  timeout: number;
}

/** 自定义错误：ArkTS 不允许给 Error 实例动态挂字段 */
export class HttpError extends Error {
  code: number;
  responseBody: string;

  constructor(code: number, responseBody: string) {
    super(`HTTP ${code}`);
    this.name = 'HttpError';
    this.code = code;
    this.responseBody = responseBody;
  }
}

/** 全局配置：服务器地址与 token（登录后写入） */
export class NetConfig {
  private static baseUrl: string = '';
  private static token: string = '';

  static setBaseUrl(url: string): void {
    NetConfig.baseUrl = url.trim().replace(/\/+$/, '');
  }

  static getBaseUrl(): string {
    return NetConfig.baseUrl;
  }

  static setToken(t: string): void {
    NetConfig.token = t;
  }

  static getToken(): string {
    return NetConfig.token;
  }

  static hasToken(): boolean {
    return NetConfig.token.length > 0;
  }

  static clear(): void {
    NetConfig.token = '';
  }
}

export class Net {
  /** 发起一次请求 */
  static async send(opts: RequestOptions): Promise<HttpResult> {
    const url = `${NetConfig.getBaseUrl()}${opts.path}`;
    const client = http.createHttp();
    const req = client.request(url, {
      method: Net.toMethod(opts.method),
      header: Net.buildHeaders(opts.token),
      extraData: opts.body,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: opts.timeout > 0 ? opts.timeout : 15000,
      readTimeout: opts.timeout > 0 ? opts.timeout : 30000,
      usingCache: false
    });

    try {
      const res = await req;
      const headers: ResponseHeaders = {
        contentType: Net.headerOf(res.header, 'content-type'),
        etag: Net.headerOf(res.header, 'etag')
      };
      const body = Net.bodyToString(res.result);
      if (res.responseCode < 200 || res.responseCode >= 300) {
        // 记到 hilog：否则真机上只弹一个 toast，hdc 抓不到日志，
        // 出了问题只能靠猜路径对不对（这次就是靠猜浪费很多时间）。
        Net.log(`← ${res.responseCode} ${opts.method} ${opts.path}  body=${body.slice(0, 180)}`);
        throw new HttpError(res.responseCode, body);
      }
      Net.log(`→ ${res.responseCode} ${opts.method} ${opts.path}`);
      const out: HttpResult = { code: res.responseCode, body: body, headers: headers };
      return out;
    } catch (e) {
      if (e instanceof HttpError) {
        throw e;
      }
      const err = e as BusinessError;
      Net.log(`✗ ${opts.method} ${opts.path}  ${err.message ?? 'unknown'}`);
      throw new Error(`网络请求失败: ${err.message ?? 'unknown'}`);
    } finally {
      client.destroy();
    }
  }

  /**
   * 统一的网络日志出口。
   * 抓法：hdc shell "hilog -x | grep NetTrace"
   */
  private static log(msg: string): void {
    try {
      hilog.info(0xD00, 'NetTrace', '%{public}s', msg);
    } catch (e) {
      // 日志失败不能影响主流程
    }
  }

  private static toMethod(m: string): http.RequestMethod {
    if (m === 'POST') {
      return http.RequestMethod.POST;
    }
    if (m === 'PUT') {
      return http.RequestMethod.PUT;
    }
    if (m === 'DELETE') {
      return http.RequestMethod.DELETE;
    }
    return http.RequestMethod.GET;
  }

  /** 逐个已知 header 取值，避开 Record 的动态下标 */
  private static headerOf(headers: Object | undefined, key: string): string {
    if (headers === undefined || headers === null) {
      return '';
    }
    const obj = headers as Record<string, string>;
    const v = obj[key];
    return typeof v === 'string' ? v : '';
  }

  private static bodyToString(result: Object | string): string {
    if (typeof result === 'string') {
      return result;
    }
    // P2-7：非 string 时返回带标记的错误提示，避免调用方把空串当正常数据
    return '[非文本响应]';
  }

  private static buildHeaders(token: string): Record<string, string> {
    // ArkTS 下Record 只能用字面量构造，逐字段填
    const h: Record<string, string> = {
      'Content-Type': 'application/json'
    };
    if (token.length > 0) {
      h['Authorization'] = `Bearer ${token}`;
    }
    return h;
  }
}

/** 请求选项工厂：ArkTS 不接受无类型的部分参数 */
export function getOpts(path: string, token: string): RequestOptions {
  return { method: 'GET', path: path, body: '', token: token, timeout: 30000 };
}

export function postOpts(path: string, body: string, token: string): RequestOptions {
  return { method: 'POST', path: path, body: body, token: token, timeout: 30000 };
}

/**
 * 自定义超时的POST。
 *
 * 为什么需要：chat-run 是**等待式**接口（跑完整个 agent 才返回），
 * 30 秒默认超时远远不够 —— 实测跑 coding agent 会到几分钟，
 * 表现为 `Operation timeout`，而服务端那边其实还在跑。
 */
export function postOptsSlow(path: string, body: string, token: string, timeoutMs: number): RequestOptions {
  return { method: 'POST', path: path, body: body, token: token, timeout: timeoutMs };
}

export function putOpts(path: string, body: string, token: string): RequestOptions {
  return { method: 'PUT', path: path, body: body, token: token, timeout: 30000 };
}

export function deleteOpts(path: string, token: string): RequestOptions {
  return { method: 'DELETE', path: path, body: '', token: token, timeout: 30000 };
}

/** 解析 JSON；空 body 返回传入的默认对象 */
export function parseJson<T>(body: string, fallback: T): T {
  if (body.length === 0) {
    return fallback;
  }
  try {
    return JSON.parse(body) as T;
  } catch (e) {
    return fallback;
  }
}

/** 提取服务端错误文案，兼容 {error} / {message} 两种形态 */
export function errorMessage(e: Object): string {
  if (e instanceof HttpError) {
    // 服务端错误体：{"error":"xxx"} 或 {"message":"xxx"}
    const body = e.responseBody;
    if (body.length === 0) {
      return `请求失败 (${e.code})`;
    }
    try {
      const parsed = JSON.parse(body) as ErrorPayloadLite;
      if (typeof parsed.error === 'string' && parsed.error.length > 0) {
        return parsed.error;
      }
      if (typeof parsed.message === 'string' && parsed.message.length > 0) {
        return parsed.message;
      }
    } catch (x) {
      return body.slice(0, 200);
    }
    return `请求失败 (${e.code})`;
  }
  const err = e as Error;
  return err.message.length > 0 ? err.message : '未知错误';
}

interface ErrorPayloadLite {
  error: string;
  message: string;
}