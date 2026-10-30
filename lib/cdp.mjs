#!/usr/bin/env node
/**
 * cdp.mjs - Codex Desktop 汉化 CDP 驱动（零 npm 依赖）
 *
 * 作用：
 *   1. 等待 renderer DevTools 端口就绪，枚举 Codex 所有渲染页面
 *      （app://-/index.html 主窗口 + detached-window 等），按主窗口优先排序；
 *   2. 对每个 page target：Page.addScriptToEvaluateOnNewDocument 注册
 *      assets/i18n-bootstrap.js，立即 Runtime.evaluate 一次并等待 Statsig 补丁完成；
 *   3. 通过 assets/locale-script.js 触发 location.reload()，让新文档先跑 bootstrap
 *      再初始化官方 i18n；刷新后重新枚举 page targets 并逐个验证，取最优结果；
 *   4. 可选：尝试连接 --inspect 暴露的 Node inspector 注入原生菜单翻译。
 *      多数 26.900+ 版本不开放该端口——这属于正常现象：官方 i18n 已覆盖原生菜单，
 *      因此菜单状态记为 not-needed，不影响整体结果，也不会判为 partial；
 *   5. 将结构化 JSON 写入 --result 文件；退出码：
 *      0 = 中文界面确认生效，1 = 界面部分中文/未完全确认，2 = 失败。
 *
 * 依赖：Node >= 22（内置 fetch / WebSocket / AbortSignal.timeout），不使用任何第三方包。
 *
 * Licensed under the MIT License.
 * 机制参考 shibaweidu/codex-desktop-zh（MIT）与社区真机验证结论，详见 THIRD_PARTY_NOTICES.md。
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_ASSETS_DIR = path.resolve(SCRIPT_DIR, '..', 'assets');

const argv = process.argv.slice(2);
function arg(name, fallback = null) {
  const index = argv.indexOf(name);
  return index >= 0 && index + 1 < argv.length ? argv[index + 1] : fallback;
}
function hasFlag(name) {
  return argv.indexOf(name) >= 0;
}

const options = {
  mode: String(arg('--mode', 'inject')),
  rendererPort: Number(arg('--renderer-port', '0')),
  inspectorPort: Number(arg('--inspector-port', '0')),
  assetsDir: path.resolve(arg('--assets-dir', DEFAULT_ASSETS_DIR)),
  resultFile: arg('--result', ''),
  logFile: arg('--log-file', ''),
  locale: String(arg('--locale', 'zh-CN')),
  platform: String(arg('--platform', 'windows')),
  rendererTimeoutMs: Number(arg('--renderer-timeout-ms', '25000')),
  preverifyTimeoutMs: Number(arg('--preverify-timeout-ms', '30000')),
  verifyTimeoutMs: Number(arg('--verify-timeout-ms', '90000')),
  menuTimeoutMs: Number(arg('--menu-timeout-ms', '6000')),
  commandTimeoutMs: Number(arg('--command-timeout-ms', '15000')),
  reloadWaitMs: Number(arg('--reload-wait-ms', '2000')),
  noReload: hasFlag('--no-reload'),
  debug: hasFlag('--debug')
};

const startedAt = Date.now();
const timings = {};
function markTiming(name, from) {
  timings[name] = Date.now() - (from || startedAt);
}

// ---------------------------------------------------------------------------
// 日志
// ---------------------------------------------------------------------------
let logStream = null;
function writeLogLine(line) {
  process.stderr.write(line + '\n');
  if (!logStream && options.logFile) {
    try {
      fs.mkdirSync(path.dirname(options.logFile), { recursive: true });
      logStream = fs.createWriteStream(options.logFile, { flags: 'a', encoding: 'utf8' });
    } catch (_) {
      logStream = null;
    }
  }
  if (logStream) {
    try { logStream.write(line + '\n'); } catch (_) {}
  }
}
function log(level, message, extra) {
  const stamp = new Date().toISOString();
  let line = '[' + stamp + '] [' + level + '] ' + message;
  if (extra !== undefined && extra !== null) {
    try {
      const text = typeof extra === 'string' ? extra : JSON.stringify(extra);
      if (text) line += ' ' + text;
    } catch (_) {}
  }
  writeLogLine(line);
}
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// ---------------------------------------------------------------------------
// 错误分类
// ---------------------------------------------------------------------------
class CdpError extends Error {
  constructor(code, message, detail) {
    super(message);
    this.name = 'CdpError';
    this.code = code;
    this.detail = detail;
  }
}

function classifyFetchError(error) {
  const text = String(error && error.message ? error.message : error);
  if (/abort|timeout|timed out/i.test(text)) return 'CDP_HTTP_TIMEOUT';
  if (/ECONNREFUSED|fetch failed|ECONNRESET|EHOSTUNREACH|ENETUNREACH/i.test(text)) return 'CDP_PORT_NOT_READY';
  return 'CDP_HTTP_ERROR';
}

// ---------------------------------------------------------------------------
// 资产加载
// ---------------------------------------------------------------------------
function readAsset(name) {
  const file = path.join(options.assetsDir, name);
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (error) {
    throw new CdpError('ASSET_MISSING', '无法读取资产文件: ' + file + ' (' + error.message + ')');
  }
}

function loadTranslations() {
  const raw = readAsset('menu-translations.json');
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    throw new CdpError('ASSET_INVALID', 'menu-translations.json 不是合法 JSON: ' + error.message);
  }
  const merged = {};
  const groups = ['common', options.platform === 'macos' ? 'macos' : 'windows'];
  for (const group of groups) {
    const value = parsed[group];
    if (value && typeof value === 'object') {
      for (const key of Object.keys(value)) merged[key] = value[key];
    }
  }
  return merged;
}

// ---------------------------------------------------------------------------
// HTTP 目标发现
// ---------------------------------------------------------------------------
async function fetchJson(url, timeoutMs) {
  let response;
  try {
    response = await fetch(url, { signal: AbortSignal.timeout(timeoutMs) });
  } catch (error) {
    throw new CdpError(classifyFetchError(error), '请求 ' + url + ' 失败: ' + String(error && error.message ? error.message : error));
  }
  if (!response.ok) {
    throw new CdpError('CDP_HTTP_ERROR', '请求 ' + url + ' 返回 HTTP ' + response.status);
  }
  try {
    return await response.json();
  } catch (error) {
    throw new CdpError('CDP_HTTP_ERROR', '请求 ' + url + ' 返回内容不是 JSON: ' + error.message);
  }
}

async function listTargets(port, timeoutMs = 3000) {
  if (!port) throw new CdpError('CDP_PORT_NOT_CONFIGURED', '未提供调试端口');
  return fetchJson('http://127.0.0.1:' + port + '/json/list', timeoutMs);
}

async function fetchVersion(port, timeoutMs = 2500) {
  if (!port) throw new CdpError('CDP_PORT_NOT_CONFIGURED', '未提供调试端口');
  return fetchJson('http://127.0.0.1:' + port + '/json/version', timeoutMs);
}

// ---------------------------------------------------------------------------
// WebSocket / CDP 连接
// ---------------------------------------------------------------------------
class CdpConnection {
  constructor(wsUrl, label) {
    this.wsUrl = wsUrl;
    this.label = label || 'cdp';
    this.ws = null;
    this.nextId = 0;
    this.pending = new Map();
    this.closed = false;
  }

  async connect(timeoutMs = 8000) {
    let ws;
    try {
      ws = new WebSocket(this.wsUrl);
    } catch (error) {
      throw new CdpError('CDP_WS_ERROR', '创建 WebSocket 失败: ' + error.message);
    }
    this.ws = ws;
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        cleanup();
        reject(new CdpError('CDP_WS_TIMEOUT', '连接 ' + this.label + ' 超时: ' + this.wsUrl));
      }, timeoutMs);
      const onOpen = () => { cleanup(); resolve(); };
      const onError = (event) => {
        cleanup();
        const detail = event && event.message ? event.message : 'WebSocket error';
        reject(new CdpError('CDP_WS_ERROR', '连接 ' + this.label + ' 失败: ' + detail));
      };
      const cleanup = () => {
        clearTimeout(timer);
        try { ws.removeEventListener('open', onOpen); } catch (_) {}
        try { ws.removeEventListener('error', onError); } catch (_) {}
      };
      ws.addEventListener('open', onOpen, { once: true });
      ws.addEventListener('error', onError, { once: true });
    });
    ws.addEventListener('message', (event) => this._onMessage(event));
    ws.addEventListener('close', () => {
      this.closed = true;
      for (const [, pending] of this.pending) {
        clearTimeout(pending.timer);
        pending.reject(new CdpError('CDP_WS_CLOSED', 'CDP 连接已关闭: ' + this.label));
      }
      this.pending.clear();
    });
    ws.addEventListener('error', () => {});
    return this;
  }

  _onMessage(event) {
    let message;
    try { message = JSON.parse(event.data); } catch (_) { return; }
    if (!message || typeof message.id !== 'number' || !this.pending.has(message.id)) return;
    const pending = this.pending.get(message.id);
    this.pending.delete(message.id);
    clearTimeout(pending.timer);
    if (message.error) {
      pending.reject(new CdpError('CDP_PROTOCOL_ERROR',
        'CDP ' + pending.method + ' 返回错误: ' + JSON.stringify(message.error)));
    } else {
      pending.resolve(message.result);
    }
  }

  send(method, params = {}, timeoutMs = options.commandTimeoutMs) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      return Promise.reject(new CdpError('CDP_WS_CLOSED', 'WebSocket 未连接，无法执行 ' + method));
    }
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new CdpError('CDP_TIMEOUT', 'CDP 调用超时: ' + method + ' (' + timeoutMs + 'ms)'));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer, method });
      try {
        this.ws.send(JSON.stringify({ id, method, params }));
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(new CdpError('CDP_WS_ERROR', '发送 ' + method + ' 失败: ' + error.message));
      }
    });
  }

  async evaluate(expression, { awaitPromise = false, timeoutMs = options.commandTimeoutMs } = {}) {
    const result = await this.send('Runtime.evaluate', {
      expression,
      awaitPromise,
      returnByValue: true,
      userGesture: true,
      allowUnsafeEvalBlockedByCSP: true
    }, timeoutMs);
    if (result && result.exceptionDetails) {
      const detail = result.exceptionDetails;
      const text = (detail.exception && (detail.exception.description || detail.exception.value)) ||
        detail.text || JSON.stringify(detail);
      throw new CdpError('CDP_EVALUATE_EXCEPTION', '注入脚本执行异常: ' + String(text).slice(0, 1200));
    }
    return result && result.result ? result.result.value : undefined;
  }

  close() {
    try { if (this.ws && this.ws.readyState === WebSocket.OPEN) this.ws.close(); } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// 注入脚本
// ---------------------------------------------------------------------------
const PROBE_SCRIPT = String.raw`(function () {
  var text = document.body ? (document.body.innerText || '') : '';
  return JSON.stringify({
    codexZhProbe: true,
    probe: true,
    readyState: document.readyState,
    hasBridge: !!(window.electronBridge && typeof window.electronBridge.sendMessageFromView === 'function'),
    hasAppRoot: !!document.querySelector('#root'),
    textLength: text.length,
    chineseChars: (text.match(/[\u4e00-\u9fa5]/g) || []).length,
    title: document.title || '',
    url: location.href
  });
})()`;

const WAIT_BOOTSTRAP_SCRIPT = String.raw`(async function () {
  var started = Date.now();
  while (Date.now() - started < 12000) {
    var state = window.__codexZhI18nState || {};
    if ((state.patchedClients || 0) > 0) break;
    await new Promise(function (resolve) { window.setTimeout(resolve, 100); });
  }
  var finalState = window.__codexZhI18nState || {};
  return JSON.stringify({
    status: (finalState.patchedClients || 0) > 0 && (finalState.patchedConfigs || 0) > 0 ? 'ok'
      : ((finalState.patchedClients || 0) > 0 ? 'patched-clients-only' : 'partial'),
    configId: '72216192',
    enable_i18n: true,
    locale_source: 'SYSTEM',
    patchedClients: finalState.patchedClients || 0,
    patchedConfigs: finalState.patchedConfigs || 0,
    attempts: finalState.attempts || 0,
    candidates: finalState.candidates || [],
    lastPatchAt: finalState.lastPatchAt || 0
  });
})()`;

const VERIFY_SCRIPT = String.raw`(async function () {
  var started = Date.now();
  while (Date.now() - started < 12000) {
    var probeText = document.body ? (document.body.innerText || '') : '';
    if (probeText.length >= 40) break;
    await new Promise(function (resolve) { window.setTimeout(resolve, 150); });
  }
  var text = document.body ? (document.body.innerText || '') : '';
  var zhMarkers = ['新建任务', '新聊天', '新会话', '拉取请求', '已安排', '插件', '设置', '项目',
    '文件', '编辑', '视图', '帮助', '随心输入', '自动化任务'];
  var enMarkers = ['New task', 'New chat', 'Pull requests', 'Scheduled', 'Plugins', 'Settings',
    'Projects', 'File', 'Edit', 'View', 'Help'];
  var count = function (list) {
    var total = 0;
    for (var i = 0; i < list.length; i++) {
      if (text.indexOf(list[i]) >= 0) total += 1;
    }
    return total;
  };
  var zhMatches = count(zhMarkers);
  var enMatches = count(enMarkers);
  var chineseChars = (text.match(/[\u4e00-\u9fa5]/g) || []).length;
  var navLang = String(navigator.language || '');
  var docLang = String(document.documentElement.lang || '');
  var state = window.__codexZhI18nState || {};
  var languageMatches = navLang.toLowerCase().indexOf('zh') === 0 && (docLang === '' || docLang.toLowerCase().indexOf('zh') === 0);
  var status = 'fail';
  if (zhMatches >= 3) status = 'ok';
  else if (zhMatches > 0 || (languageMatches && chineseChars > 0) || (state.patchedClients || 0) > 0) status = 'partial';
  return JSON.stringify({
    status: status,
    navigatorLanguage: navLang,
    documentLanguage: docLang,
    languageMatches: languageMatches,
    zhMatches: zhMatches,
    enMatches: enMatches,
    zhMarkers: zhMarkers,
    enMarkers: enMarkers,
    chineseChars: chineseChars,
    textLength: text.length,
    readyState: document.readyState,
    url: String(location.href || ''),
    i18nState: {
      patchedClients: state.patchedClients || 0,
      patchedConfigs: state.patchedConfigs || 0,
      candidates: state.candidates || []
    },
    sample: text.replace(/\s+/g, ' ').slice(0, 1200)
  });
})()`;

// ---------------------------------------------------------------------------
// 目标发现 / 验证
// ---------------------------------------------------------------------------
const RENDERER_TYPES = ['page', 'iframe', 'webview'];

function isRendererTarget(target) {
  return target && RENDERER_TYPES.indexOf(String(target.type)) >= 0 && !!target.webSocketDebuggerUrl;
}

function isCodexRendererTarget(target) {
  return isRendererTarget(target) && String(target.url || '').indexOf('app://-/') === 0;
}

function targetSummary(target) {
  if (!target) return null;
  return {
    id: target.id,
    type: target.type,
    title: target.title || '',
    url: target.url || ''
  };
}

function targetLabel(target) {
  return String((target && target.type) || '') + ' ' + String((target && target.url) || '') + ' ' + String((target && target.title) || '');
}

// 主窗口优先：index.html 且不带 initialRoute / 非 detached-window 的 page 排最前
function targetPreference(target) {
  const url = String((target && target.url) || '');
  let score = 0;
  if (url.indexOf('index.html') >= 0) score += 100000;
  if (url.indexOf('initialRoute') < 0) score += 50000;
  if (url.indexOf('detached-window') >= 0) score -= 200000;
  if (String(target && target.type) === 'page') score += 1000;
  return score;
}

async function listCodexRendererTargets(port, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let lastError = null;
  while (Date.now() < deadline) {
    let targets = null;
    try {
      targets = await listTargets(port, 3000);
    } catch (error) {
      lastError = error;
      await sleep(400);
      continue;
    }
    if (!Array.isArray(targets)) {
      lastError = new CdpError('CDP_HTTP_ERROR', '/json/list 返回内容不是数组');
      await sleep(400);
      continue;
    }
    let rendererTargets = targets.filter(isCodexRendererTarget);
    if (rendererTargets.length === 0) rendererTargets = targets.filter(isRendererTarget);
    if (rendererTargets.length > 0) {
      rendererTargets.sort((left, right) => targetPreference(right) - targetPreference(left));
      return rendererTargets;
    }
    await sleep(400);
  }
  const suffix = lastError ? '，最后错误: ' + lastError.message : '';
  throw new CdpError('CDP_TARGET_TIMEOUT',
    '未在 ' + Math.round(timeoutMs / 1000) + ' 秒内找到 Codex 渲染页面（端口 ' + port + '）' + suffix);
}

function verifyRank(verify) {
  if (!verify) return -1;
  let rank = 0;
  if (verify.status === 'ok') rank += 100000;
  else if (verify.status === 'partial') rank += 10000;
  rank += (Number(verify.chineseChars) || 0);
  rank += (Number(verify.zhMatches) || 0) * 1000;
  return rank;
}

async function verifyOneTarget(target) {
  const item = { target: targetSummary(target), verify: null, error: null };
  const connection = new CdpConnection(target.webSocketDebuggerUrl, 'verify:' + target.id);
  try {
    await connection.connect(8000);
    const raw = await connection.evaluate(VERIFY_SCRIPT, { awaitPromise: true, timeoutMs: 20000 });
    item.verify = typeof raw === 'string' ? JSON.parse(raw) : raw;
  } catch (error) {
    item.error = error.message;
  } finally {
    connection.close();
  }
  return item;
}

async function verifyAllTargets(port, deadline) {
  const remaining = Math.max(3000, Math.min(10000, deadline - Date.now()));
  const pages = await listCodexRendererTargets(port, remaining);
  const results = [];
  let best = null;
  for (const page of pages.slice(0, 8)) {
    const item = await verifyOneTarget(page);
    results.push(item);
    if (!best || verifyRank(item.verify) > verifyRank(best.verify)) best = item;
  }
  return { results, best };
}

/**
 * 在新版本上，官方 i18n 会在应用启动后 10~30 秒内随 localeOverride/--lang 自动生效。
 * 先等待一段时间，若已中文则无需注入，避免不必要的页面刷新。
 */
async function waitForChinese(port, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let best = null;
  let results = [];
  let attempts = 0;
  let lastError = null;
  while (Date.now() < deadline) {
    attempts += 1;
    try {
      const pass = await verifyAllTargets(port, deadline);
      results = pass.results;
      if (pass.best && verifyRank(pass.best.verify) > verifyRank(best && best.verify)) best = pass.best;
      const verify = best && best.verify;
      log('info', '官方 locale 预检', {
        pass: attempts,
        targetUrl: best && best.target ? best.target.url : '',
        status: verify ? verify.status : '',
        chineseChars: verify ? verify.chineseChars : 0,
        zhMatches: verify ? verify.zhMatches : 0,
        documentLanguage: verify ? verify.documentLanguage : ''
      });
      if (verify && verify.status === 'ok') {
        return { ok: true, best, results, attempts };
      }
    } catch (error) {
      lastError = error;
    }
    await sleep(1500);
  }
  return { ok: false, best, results, attempts, error: lastError };
}

// ---------------------------------------------------------------------------
// 阶段一：renderer 注入 + 刷新 + 逐个验证
// ---------------------------------------------------------------------------
async function injectRenderer() {
  const phaseStart = Date.now();
  const result = {
    ok: false,
    mode: 'runtime-injection',
    skippedInjection: false,
    port: options.rendererPort,
    target: null,
    probe: null,
    preverify: null,
    targetsInjected: [],
    verified: [],
    verify: null,
    addScript: null,
    bootstrap: null,
    bootstrapWait: null,
    reload: null,
    attempts: 0,
    error: null,
    warnings: []
  };

  try {
    const version = await fetchVersion(options.rendererPort, 4000).catch(() => null);
    if (version) log('info', 'renderer /json/version 可用，Browser=' + (version.Browser || 'unknown'));
    markTiming('rendererVersionMs', phaseStart);

    // 1) 枚举所有 Codex 渲染页面（主窗口在前）
    const targets = await listCodexRendererTargets(options.rendererPort, options.rendererTimeoutMs);
    log('info', '发现 Codex 渲染页面 ' + targets.length + ' 个', targets.map(targetLabel));
    markTiming('rendererTargetMs', phaseStart);

    // 1.5) 先等待官方 locale 生效：较新版本中 localeOverride + --lang 会让官方 i18n
    //      在启动后约 10~30 秒内自动加载 zh-CN；此时无需注入和刷新。
    const pre = await waitForChinese(options.rendererPort, options.preverifyTimeoutMs);
    result.preverify = {
      ok: pre.ok,
      attempts: pre.attempts,
      status: pre.best && pre.best.verify ? pre.best.verify.status : '',
      chineseChars: pre.best && pre.best.verify ? (pre.best.verify.chineseChars || 0) : 0,
      targetUrl: pre.best && pre.best.target ? pre.best.target.url : ''
    };
    if (pre.ok) {
      result.mode = 'official-locale';
      result.skippedInjection = true;
      result.target = pre.best.target;
      result.verify = Object.assign({}, pre.best.verify);
      result.verified = pre.results;
      result.attempts = pre.attempts;
      result.ok = true;
      markTiming('verifyMs', phaseStart);
      log('info', '官方 locale 已生效，跳过运行时注入');
      return result;
    }
    log('info', '官方 locale 预检未生效，进入运行时注入流程');

    const bootstrapSource = readAsset('i18n-bootstrap.js');
    const localeSource = readAsset('locale-script.js');
    const primaryCandidate = targets.find((target) =>
      String(target.type) === 'page' && String(target.url || '').indexOf('index.html') >= 0) || targets[0];

    // 2) 对每个 page target 注入（iframe/webview 只记录不注入）
    for (const target of targets.slice(0, 8)) {
      const item = {
        target: targetSummary(target),
        probe: null,
        addScript: null,
        bootstrap: null,
        bootstrapWait: null,
        reload: null,
        error: null
      };
      if (String(target.type) !== 'page') {
        item.error = 'non-page-target';
        result.targetsInjected.push(item);
        continue;
      }
      let connection = null;
      try {
        connection = new CdpConnection(target.webSocketDebuggerUrl, 'inject:' + target.id);
        await connection.connect(8000);
        try {
          const probeRaw = await connection.evaluate(PROBE_SCRIPT, { timeoutMs: 8000 });
          item.probe = typeof probeRaw === 'string' ? JSON.parse(probeRaw) : probeRaw;
        } catch (error) {
          item.probe = { error: error.message };
        }
        // 注册“新文档最先执行”的 bootstrap（跨该 target 后续导航持续生效）
        try {
          const added = await connection.send('Page.addScriptToEvaluateOnNewDocument', {
            source: bootstrapSource,
            runImmediately: true
          }, 10000);
          item.addScript = { ok: true, identifier: added && added.identifier ? added.identifier : '' };
        } catch (error) {
          item.addScript = { ok: false, error: error.message };
          result.warnings.push('addScript 注册失败（' + targetLabel(target) + '）: ' + error.message);
        }
        // 立即在当前文档执行一次（新文档脚本不会作用于已存在的文档）
        try {
          const raw = await connection.evaluate(bootstrapSource, { awaitPromise: false, timeoutMs: 15000 });
          item.bootstrap = typeof raw === 'string' ? JSON.parse(raw) : raw;
        } catch (error) {
          item.bootstrap = { status: 'error', error: error.message };
          result.warnings.push('bootstrap 当前文档执行失败（' + targetLabel(target) + '）: ' + error.message);
        }
        // 等待 Statsig 补丁真正完成（最多 12s）
        try {
          const raw = await connection.evaluate(bootstrapSource + ';\n' + WAIT_BOOTSTRAP_SCRIPT, {
            awaitPromise: true,
            timeoutMs: 20000
          });
          item.bootstrapWait = typeof raw === 'string' ? JSON.parse(raw) : raw;
        } catch (error) {
          item.bootstrapWait = { status: 'error', error: error.message };
          result.warnings.push('bootstrap 等待失败（' + targetLabel(target) + '）: ' + error.message);
        }
        // 刷新页面：新文档会先执行 bootstrap，再初始化官方 i18n
        if (!options.noReload) {
          try {
            const raw = await connection.evaluate(localeSource, { awaitPromise: false, timeoutMs: 8000 });
            item.reload = typeof raw === 'string' ? JSON.parse(raw) : raw;
          } catch (error) {
            item.reload = { status: 'error', error: error.message };
            result.warnings.push('location.reload 调用失败（' + targetLabel(target) + '）: ' + error.message);
          }
        } else {
          item.reload = { status: 'skipped', action: 'none' };
        }
      } catch (error) {
        item.error = error.message;
        result.warnings.push('注入目标失败（' + targetLabel(target) + '）: ' + error.message);
        log('warn', '注入目标失败', { target: targetLabel(target), error: error.message });
      } finally {
        if (connection) connection.close();
      }
      result.targetsInjected.push(item);
    }
    markTiming('bootstrapMs', phaseStart);

    const primaryInjected = result.targetsInjected.find((item) => !item.error) || null;
    if (primaryInjected) {
      result.target = primaryInjected.target;
      result.probe = primaryInjected.probe;
      result.addScript = primaryInjected.addScript;
      result.bootstrap = primaryInjected.bootstrap;
      result.bootstrapWait = primaryInjected.bootstrapWait;
      result.reload = primaryInjected.reload;
    }
    log('info', '已注入页面数', result.targetsInjected.filter((item) => !item.error).length);

    // 3) 等页面重新加载，然后重新枚举所有 page target 逐个验证
    if (!options.noReload) await sleep(options.reloadWaitMs);
    const verifyDeadline = Date.now() + options.verifyTimeoutMs;
    let best = null;
    let lastError = null;
    let pass = 0;
    while (Date.now() < verifyDeadline) {
      pass += 1;
      let verifiedPass;
      try {
        verifiedPass = await verifyAllTargets(options.rendererPort, verifyDeadline);
      } catch (error) {
        lastError = error;
        log('warn', '验证尝试失败', { pass: pass, error: error.message });
        await sleep(1200);
        continue;
      }
      result.verified = verifiedPass.results;
      result.attempts = pass;
      if (verifiedPass.best) {
        best = verifiedPass.best;
        const bestVerify = best.verify || {};
        log('info', '验证结果', {
          pass: pass,
          targetUrl: best.target ? best.target.url : '',
          status: bestVerify.status,
          zhMatches: bestVerify.zhMatches,
          enMatches: bestVerify.enMatches,
          chineseChars: bestVerify.chineseChars,
          navigatorLanguage: bestVerify.navigatorLanguage,
          documentLanguage: bestVerify.documentLanguage
        });
        if (bestVerify.status === 'ok' || (Number(bestVerify.chineseChars) || 0) > 80) break;
      }
      await sleep(1500);
    }
    if (!best) {
      throw lastError || new CdpError('VERIFY_FAILED', '未获取到任何可验证的 Codex 渲染页面');
    }
    result.target = best.target;
    result.verify = best.verify;
    result.ok = !!(best.verify && best.verify.status !== 'fail');
    markTiming('verifyMs', phaseStart);
    log('info', 'renderer 注入完成', { ok: result.ok, url: best.target ? best.target.url : '' });
    return result;
  } catch (error) {
    result.error = {
      code: error.code || 'CDP_RENDERER_FAILED',
      message: error.message,
      detail: error.detail || null
    };
    result.ok = false;
    log('error', 'renderer 注入阶段失败', result.error);
    return result;
  }
}

// ---------------------------------------------------------------------------
// 阶段二：主进程 inspector → 原生菜单翻译（可选增强）
// ---------------------------------------------------------------------------
async function injectMenu() {
  const phaseStart = Date.now();
  const result = {
    required: false,
    status: 'not-needed',
    reason: '',
    note: '',
    port: options.inspectorPort,
    target: null,
    changed: 0,
    inspected: 0,
    untranslated: [],
    topLabels: [],
    attempts: [],
    error: null
  };
  if (!options.inspectorPort) {
    result.reason = 'inspector-port-not-configured';
    return result;
  }
  try {
    let targets;
    try {
      targets = await waitForJsonList(options.inspectorPort, options.menuTimeoutMs);
    } catch (error) {
      // 多数 26.900+ 版本不开放 --inspect：官方 i18n 已覆盖原生菜单，属正常现象
      result.status = 'not-needed';
      result.reason = 'inspector-port-not-open';
      result.note = '当前 Codex 版本未开放主进程 inspector；官方 i18n 已覆盖原生菜单，无需注入。';
      log('info', '主进程 inspector 端口未开放（正常现象，菜单由官方 i18n 覆盖）', { port: options.inspectorPort });
      markTiming('menuMs', phaseStart);
      return result;
    }
    const list = Array.isArray(targets) ? targets : [];
    const nodeTarget = list.find((target) => String(target.type) === 'node' && target.webSocketDebuggerUrl);
    if (!nodeTarget) {
      result.status = 'not-needed';
      result.reason = 'node-target-not-found';
      result.note = 'inspector 端口有响应但没有 node target；菜单由官方 i18n 覆盖，无需注入。';
      log('info', 'inspector 端口已开放但没有 node target（不影响汉化）', { types: list.map((t) => t.type) });
      markTiming('menuMs', phaseStart);
      return result;
    }
    result.target = targetSummary(nodeTarget);
    const translations = loadTranslations();
    let script = readAsset('menu-script.js')
      .replace('__TRANSLATIONS_JSON__', JSON.stringify(translations))
      .replace('__PLATFORM_JSON__', JSON.stringify(options.platform));
    if (script.indexOf('__TRANSLATIONS_JSON__') >= 0 || script.indexOf('__PLATFORM_JSON__') >= 0) {
      throw new CdpError('ASSET_INVALID', 'menu-script.js 占位符未被正确替换');
    }
    const connection = new CdpConnection(nodeTarget.webSocketDebuggerUrl, 'menu');
    try {
      await connection.connect(8000);
      const raw = await connection.evaluate(script, { awaitPromise: false, timeoutMs: 20000 });
      const parsed = typeof raw === 'string' ? JSON.parse(raw) : raw;
      if (!parsed || typeof parsed !== 'object') {
        throw new CdpError('CDP_EVALUATE_EXCEPTION', '菜单脚本返回内容不是 JSON 对象');
      }
      const parsedStatus = String(parsed.status || 'partial');
      result.status = parsedStatus === 'skipped' ? 'unavailable' : parsedStatus;
      result.reason = parsed.reason || (parsedStatus === 'skipped' ? 'electron-menu-unavailable' : '');
      result.changed = parsed.changed || 0;
      result.inspected = parsed.inspected || 0;
      result.untranslated = Array.isArray(parsed.untranslated) ? parsed.untranslated : [];
      result.topLabels = Array.isArray(parsed.topLabels) ? parsed.topLabels : [];
      result.attempts = Array.isArray(parsed.attempts) ? parsed.attempts : [];
      log('info', '菜单注入结果（可选增强）', {
        status: result.status,
        changed: result.changed,
        inspected: result.inspected,
        untranslated: result.untranslated.length
      });
    } finally {
      connection.close();
    }
    markTiming('menuMs', phaseStart);
    return result;
  } catch (error) {
    result.status = 'error';
    result.reason = error.code || 'MENU_INJECTION_FAILED';
    result.error = { code: error.code || 'MENU_INJECTION_FAILED', message: error.message };
    log('warn', '菜单注入失败（可选增强，不影响界面汉化）', result.error);
    markTiming('menuMs', phaseStart);
    return result;
  }
}

async function waitForJsonList(port, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      return await listTargets(port, 2500);
    } catch (error) {
      lastError = error;
      await sleep(250);
    }
  }
  throw lastError || new CdpError('CDP_PORT_NOT_READY', '调试端口 ' + port + ' 未就绪');
}

// ---------------------------------------------------------------------------
// 结果汇总
// ---------------------------------------------------------------------------
function menuVerdict(menu) {
  const status = String((menu && menu.status) || 'not-needed');
  if (status === 'ok') return { ok: true, usable: true, label: 'official-i18n+menu-script' };
  if (status === 'partial') return { ok: true, usable: true, label: 'menu-script-partial' };
  if (status === 'not-needed') return { ok: true, usable: false, label: 'official-i18n' };
  if (status === 'unavailable' || status === 'skipped') return { ok: true, usable: false, label: status };
  return { ok: false, usable: false, label: status };
}

function buildChecks(renderer, menu) {
  const checks = [];
  const push = (name, ok, detail) => checks.push({ name, ok: !!ok, detail: detail || '' });
  const injected = (renderer && renderer.targetsInjected) || [];
  const verify = (renderer && renderer.verify) || {};
  const menuState = menuVerdict(menu);
  const skipped = !!(renderer && renderer.skippedInjection);
  push('renderer-port-ready', !!(renderer && renderer.target), renderer && renderer.target
    ? 'port=' + options.rendererPort : 'renderer target 未找到');
  push('renderer-target-found', !!(renderer && renderer.target && renderer.target.id),
    renderer && renderer.target ? renderer.target.url : '');
  push('official-locale', skipped,
    skipped ? 'localeOverride + --lang 已生效，无需运行时注入' : '预检窗口内未生效，已执行运行时注入');
  push('targets-injected', skipped ? true : injected.length > 0,
    skipped ? 'skipped(official-locale)' : 'count=' + injected.length);
  push('add-script-registered', skipped ? true :
    injected.some((item) => item.addScript && item.addScript.ok), skipped ? 'skipped' : '');
  push('statsig-patched', skipped ? true :
    injected.some((item) => item.bootstrapWait && (item.bootstrapWait.patchedClients || 0) > 0),
    skipped ? 'skipped(official-locale)' : JSON.stringify(injected.map((item) => ({
      url: item.target ? item.target.url : '',
      patchedClients: item.bootstrapWait && item.bootstrapWait.patchedClients,
      patchedConfigs: item.bootstrapWait && item.bootstrapWait.patchedConfigs
    }))).slice(0, 500));
  push('page-reloaded', skipped ? true : injected.some((item) => item.reload && item.reload.status !== 'error'),
    skipped ? 'skipped' : 'targets=' + injected.length);
  push('navigator-language', String(verify.navigatorLanguage || '').toLowerCase().indexOf('zh') === 0,
    verify.navigatorLanguage || '');
  push('document-language', String(verify.documentLanguage || '').toLowerCase().indexOf('zh') === 0,
    verify.documentLanguage || '');
  push('ui-chinese', verify.status === 'ok' || verify.status === 'partial',
    'status=' + (verify.status || 'unknown') + ';chars=' + (verify.chineseChars || 0) +
    ';zh=' + (verify.zhMatches || 0) + ';en=' + (verify.enMatches || 0));
  push('native-menu', menuState.ok, 'mode=' + menuState.label +
    (menu && menu.reason ? ';reason=' + menu.reason : '') +
    (menu && menu.status === 'not-needed' ? ';官方 i18n 已覆盖菜单，无需注入' : ''));
  return checks;
}

function summarize(renderer, menu) {
  const verify = (renderer && renderer.verify) || {};
  const rendererOk = verify.status === 'ok';
  const rendererPartial = verify.status === 'partial';
  const menuState = menuVerdict(menu);
  let status = 'failed';
  let code = 'VERIFY_FAILED';
  let exitCode = 2;
  if (rendererOk) {
    status = 'complete';
    code = 'OK';
    exitCode = 0;
  } else if (rendererPartial) {
    status = 'partial';
    code = 'PARTIAL_RENDERER';
    exitCode = 1;
  } else if (renderer && renderer.error) {
    code = renderer.error.code || 'CDP_FAILED';
  }
  const warnings = (renderer && renderer.warnings) ? renderer.warnings.slice() : [];
  if (menu && menu.status === 'error') {
    warnings.push('menu-script 注入失败（可选增强，不影响界面汉化）: ' +
      (menu.error && menu.error.message ? menu.error.message : menu.reason));
  }
  return {
    status,
    code,
    exitCode,
    rendererOk,
    rendererPartial,
    menuUsable: menuState.usable,
    menuLabel: menuState.label,
    warnings
  };
}

// ---------------------------------------------------------------------------
// 其它 mode
// ---------------------------------------------------------------------------
async function runProbeMode() {
  const output = { mode: 'probe', ok: false, code: 'CDP_FAILED', port: options.rendererPort, targets: [], version: null, error: null };
  try {
    output.version = await fetchVersion(options.rendererPort, 4000).catch(() => null);
    const targets = await listCodexRendererTargets(options.rendererPort, options.rendererTimeoutMs);
    for (const target of targets.slice(0, 8)) {
      const item = { target: targetSummary(target), probe: null, error: null };
      try {
        const connection = new CdpConnection(target.webSocketDebuggerUrl, 'probe');
        try {
          await connection.connect(6000);
          const raw = await connection.evaluate(PROBE_SCRIPT, { timeoutMs: 8000 });
          item.probe = typeof raw === 'string' ? JSON.parse(raw) : raw;
        } finally {
          connection.close();
        }
      } catch (error) {
        item.error = error.message;
      }
      output.targets.push(item);
    }
    output.ok = output.targets.some((item) => item.probe);
    output.code = output.ok ? 'OK' : 'CDP_TARGET_TIMEOUT';
  } catch (error) {
    output.error = { code: error.code || 'CDP_FAILED', message: error.message };
    output.code = output.error.code;
  }
  return { output, exitCode: output.ok ? 0 : 2 };
}

async function runVerifyMode() {
  const output = { mode: 'verify', ok: false, code: 'CDP_FAILED', port: options.rendererPort, verified: [], verify: null, target: null, error: null };
  try {
    const deadline = Date.now() + options.verifyTimeoutMs;
    const pass = await verifyAllTargets(options.rendererPort, deadline);
    output.verified = pass.results;
    if (pass.best) {
      output.target = pass.best.target;
      output.verify = pass.best.verify;
      output.ok = !!(pass.best.verify && pass.best.verify.status !== 'fail');
      output.code = output.ok ? 'OK' : 'VERIFY_FAILED';
    } else {
      output.error = { code: 'VERIFY_FAILED', message: '未获取到可验证的 Codex 页面' };
      output.code = 'VERIFY_FAILED';
    }
  } catch (error) {
    output.error = { code: error.code || 'CDP_FAILED', message: error.message };
    output.code = output.error.code;
    output.ok = false;
  }
  return { output, exitCode: output.ok ? 0 : 2 };
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
async function main() {
  const result = {
    ok: false,
    status: 'failed',
    code: 'UNKNOWN',
    exitCode: 2,
    mode: options.mode,
    tool: 'codex-desktop-zh/cdp.mjs',
    locale: options.locale,
    ports: { renderer: options.rendererPort, inspector: options.inspectorPort },
    startedAt: new Date(startedAt).toISOString(),
    finishedAt: '',
    timings,
    renderer: null,
    menu: null,
    checks: [],
    warnings: [],
    errors: []
  };
  let exitCode = 2;

  log('info', 'codex-desktop-zh cdp 驱动启动', {
    mode: options.mode,
    rendererPort: options.rendererPort,
    inspectorPort: options.inspectorPort,
    assetsDir: options.assetsDir
  });

  try {
    if (options.mode === 'probe') {
      const { output, exitCode: probeExit } = await runProbeMode();
      Object.assign(result, output, {
        exitCode: probeExit,
        ok: output.ok,
        status: output.ok ? 'complete' : 'failed',
        code: output.code
      });
      result.renderer = output;
      exitCode = probeExit;
    } else if (options.mode === 'verify') {
      const { output, exitCode: verifyExit } = await runVerifyMode();
      Object.assign(result, output, {
        exitCode: verifyExit,
        ok: output.ok,
        status: output.ok ? 'complete' : 'failed',
        code: output.code
      });
      result.renderer = output;
      exitCode = verifyExit;
    } else if (options.mode === 'inject') {
      if (!options.rendererPort) throw new CdpError('CDP_PORT_NOT_CONFIGURED', '缺少 --renderer-port 参数');
      const renderer = await injectRenderer();
      const menu = await injectMenu();
      result.renderer = renderer;
      result.menu = menu;
      result.checks = buildChecks(renderer, menu);
      const summary = summarize(renderer, menu);
      result.ok = summary.status === 'complete' || summary.status === 'partial';
      result.status = summary.status;
      result.code = summary.code;
      result.exitCode = summary.exitCode;
      exitCode = summary.exitCode;
      result.warnings = summary.warnings;
      if (renderer.error) result.errors.push(renderer.error);
    } else {
      throw new CdpError('INVALID_ARGUMENT', '未知 mode: ' + options.mode);
    }
  } catch (error) {
    result.ok = false;
    result.status = 'failed';
    result.code = error.code || 'CDP_FAILED';
    result.exitCode = 2;
    result.errors.push({ code: error.code || 'CDP_FAILED', message: error.message, detail: error.detail || null });
    exitCode = 2;
    log('error', '未捕获的失败', { code: error.code || 'CDP_FAILED', message: error.message });
  }

  result.finishedAt = new Date().toISOString();
  result.durationMs = Date.now() - startedAt;
  result.timings = timings;

  const json = JSON.stringify(result, null, 2) + '\n';
  if (options.resultFile) {
    try {
      fs.mkdirSync(path.dirname(options.resultFile), { recursive: true });
      fs.writeFileSync(options.resultFile, json, 'utf8');
      log('info', '结果已写入 ' + options.resultFile);
    } catch (error) {
      log('error', '结果文件写入失败: ' + error.message);
    }
  }
  process.stdout.write(json);
  if (logStream) {
    try { logStream.end(); } catch (_) {}
  }
  process.exit(exitCode);
}

main().catch((error) => {
  log('error', '顶层异常', { message: error && error.message ? error.message : String(error) });
  process.exit(2);
});
