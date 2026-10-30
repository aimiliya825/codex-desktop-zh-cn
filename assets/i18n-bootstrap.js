/*!
 * i18n-bootstrap.js - Codex Desktop 中文界面引导脚本（运行时注入，不修改任何官方文件）
 *
 * 来源与许可：
 *   本文件基于 shibaweidu/codex-desktop-zh 项目的 shared/i18n-bootstrap.js（MIT）
 *   Copyright (c) 2026 Codex Zh Launcher contributors
 *   本仓库的修改：增加多全局对象名探测、属性 setter 挂钩与候选对象扫描，
 *   并补充返回字段；核心 Statsig 补丁思路保持一致。
 *   Licensed under the MIT License. 详见 THIRD_PARTY_NOTICES.md。
 *
 * 作用：
 *   在渲染进程（renderer）里把官方 Statsig 动态配置 72216192 的
 *   enable_i18n 强制为 true、locale_source 强制为 'SYSTEM'，
 *   并覆盖 navigator.language / navigator.languages，使 Codex 官方内置
 *   的 zh-CN 语言包真正被加载。
 *
 * 约定期望：
 *   本文件是一个“表达式型 IIFE”，最后 return 一个 JSON 字符串，
 *   便于通过 CDP Runtime.evaluate 直接取回结果。
 *   同时会把状态写到 globalThis.__codexZhI18nState，供后续轮询与验证脚本读取。
 *   本脚本可重复执行（幂等），重复执行不会重复计数。
 */
(function () {
  var configId = '72216192';
  var locale = 'zh-CN';
  var state = globalThis.__codexZhI18nState || {
    configId: configId,
    locale: locale,
    patchedClients: 0,
    patchedConfigs: 0,
    lastPatchAt: 0,
    attempts: 0,
    candidates: []
  };
  try { globalThis.__codexZhI18nState = state; } catch (_) {}

  function noteCandidate(name) {
    try {
      if (state.candidates.indexOf(name) < 0 && state.candidates.length < 32) {
        state.candidates.push(name);
      }
    } catch (_) {}
  }

  // ---- 配置对象层：包住 get() 与 value，强制 enable_i18n / locale_source ----
  function forceConfig(config) {
    if (!config || (typeof config !== 'object' && typeof config !== 'function')) return config;
    if (config.__codexZhI18nConfig) return config;
    try {
      Object.defineProperty(config, '__codexZhI18nConfig', { value: true, configurable: true });
    } catch (_) {}
    if (typeof config.get === 'function') {
      var originalGet = config.get;
      try {
        Object.defineProperty(config, 'get', {
          configurable: true,
          value: function (key, fallback) {
            if (key === 'enable_i18n') return true;
            if (key === 'locale_source') return 'SYSTEM';
            return originalGet.call(this, key, fallback);
          }
        });
      } catch (_) {}
    }
    try {
      if (config.value && typeof config.value === 'object') {
        config.value.enable_i18n = true;
        config.value.locale_source = 'SYSTEM';
      }
    } catch (_) {}
    state.patchedConfigs += 1;
    state.lastPatchAt = Date.now();
    return config;
  }

  // ---- 客户端层：包住 getDynamicConfig / getLayer，命中 72216192 时打补丁 ----
  function patchClient(client) {
    if (!client || (typeof client !== 'object' && typeof client !== 'function')) return;
    if (client.__codexZhI18nClient) return;
    var originalDynamic = client.getDynamicConfig;
    var originalLayer = client.getLayer;
    if (typeof originalDynamic !== 'function' && typeof originalLayer !== 'function') return;
    var patched = false;
    try {
      if (typeof originalDynamic === 'function') {
        Object.defineProperty(client, 'getDynamicConfig', {
          configurable: true,
          value: function (key) {
            var result = originalDynamic.apply(this, arguments);
            return String(key) === configId ? forceConfig(result) : result;
          }
        });
        patched = true;
      }
      if (typeof originalLayer === 'function') {
        Object.defineProperty(client, 'getLayer', {
          configurable: true,
          value: function (key) {
            var result = originalLayer.apply(this, arguments);
            return String(key) === configId ? forceConfig(result) : result;
          }
        });
        patched = true;
      }
      if (!patched) return;
      Object.defineProperty(client, '__codexZhI18nClient', { value: true, configurable: true });
      state.patchedClients += 1;
      state.lastPatchAt = Date.now();
    } catch (_) {}
  }

  // ---- 全局对象层：兼容 __STATSIG__ / Statsig / statsig 等多种暴露方式 ----
  function patchGlobal(statsig, name) {
    if (!statsig || typeof statsig !== 'object') return;
    noteCandidate(name || '?');
    patchClient(statsig);
    try { patchClient(statsig.firstInstance); } catch (_) {}
    try { patchClient(statsig.instance); } catch (_) {}
    try {
      var instances = statsig.instances;
      if (instances && typeof instances === 'object') {
        Object.keys(instances).forEach(function (key) { patchClient(instances[key]); });
      }
    } catch (_) {}
    try {
      // 有些构建把 Statsig SDK 放在 client 字段下
      if (statsig.client && typeof statsig.client === 'object' && statsig.client !== statsig) {
        patchClient(statsig.client);
      }
    } catch (_) {}
  }

  var GLOBAL_NAMES = [
    '__STATSIG__',
    'Statsig',
    'statsig',
    '__statsig',
    'statsigClient',
    'StatsigClient',
    '__STATSIG_CLIENT__',
    '__statsigClient'
  ];

  // 对某个全局名挂钩：先补当前值，再用 setter 拦截后续赋值（Statsig 往往延迟初始化）
  function hookGlobalName(name) {
    var current = null;
    try { current = globalThis[name]; } catch (_) {}
    try {
      if (typeof current === 'object' && current) patchGlobal(current, name);
    } catch (_) {}
    try {
      var descriptor = Object.getOwnPropertyDescriptor(globalThis, name);
      if (descriptor && descriptor.configurable === false) return;
      var stored = current;
      Object.defineProperty(globalThis, name, {
        configurable: true,
        enumerable: descriptor ? !!descriptor.enumerable : false,
        get: function () { return stored; },
        set: function (next) {
          stored = next;
          try { if (typeof next === 'object' && next) patchGlobal(next, name); } catch (_) {}
        }
      });
    } catch (_) {}
  }

  // 兜底：扫描 globalThis 上名字像 statsig 的对象（限制数量，避免性能问题）
  function scanGlobalNames() {
    var keys;
    try { keys = Object.getOwnPropertyNames(globalThis); } catch (_) { return; }
    for (var i = 0; i < keys.length && i < 2000; i++) {
      var key = keys[i];
      if (typeof key !== 'string' || !/statsig/i.test(key)) continue;
      try {
        var value = globalThis[key];
        if (value && typeof value === 'object') patchGlobal(value, key);
      } catch (_) {}
    }
  }

  function patchCurrentGlobals() {
    state.attempts += 1;
    for (var i = 0; i < GLOBAL_NAMES.length; i++) {
      var name = GLOBAL_NAMES[i];
      try {
        var value = globalThis[name];
        if (value && typeof value === 'object') patchGlobal(value, name);
      } catch (_) {}
    }
    if (state.patchedClients === 0) scanGlobalNames();
  }

  function installStatsigHook() {
    hookGlobalName('__STATSIG__');
    hookGlobalName('Statsig');
    hookGlobalName('statsig');
    patchCurrentGlobals();
    var timer = window.setInterval(function () {
      patchCurrentGlobals();
      if (state.attempts >= 400 || (state.patchedClients > 0 && state.patchedConfigs > 0)) {
        window.clearInterval(timer);
      }
    }, 50);
  }

  // ---- 浏览器语言覆盖（官方 i18n 的另一个输入） ----
  function installNavigatorOverride() {
    var getLanguage = function () { return locale; };
    var getLanguages = function () { return [locale, 'zh']; };
    var targets = [];
    try { if (typeof Navigator !== 'undefined' && Navigator.prototype) targets.push(Navigator.prototype); } catch (_) {}
    try { if (window.navigator) targets.push(window.navigator); } catch (_) {}
    for (var i = 0; i < targets.length; i++) {
      try {
        Object.defineProperty(targets[i], 'language', { configurable: true, get: getLanguage });
        Object.defineProperty(targets[i], 'languages', { configurable: true, get: getLanguages });
      } catch (_) {}
    }
  }

  try { installNavigatorOverride(); } catch (_) {}
  try { installStatsigHook(); } catch (_) {}

  return JSON.stringify({
    status: state.patchedClients > 0 && state.patchedConfigs > 0 ? 'ok' : 'pending',
    configId: configId,
    locale: locale,
    enable_i18n: true,
    locale_source: 'SYSTEM',
    patchedClients: state.patchedClients,
    patchedConfigs: state.patchedConfigs,
    attempts: state.attempts,
    candidates: state.candidates,
    lastPatchAt: state.lastPatchAt
  });
})()
