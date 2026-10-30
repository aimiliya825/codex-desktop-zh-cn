/*!
 * locale-script.js - 刷新页面使 i18n 引导生效（运行时脚本，不修改任何官方文件）
 *
 * 历史说明：
 *   旧版本汉化工具通过渲染进程旧版设置桥写入 localeOverride。经实测，
 *   Codex Desktop 26.1023 已移除该旧接口，因此本仓库改为“启动前直接写
 *   config.toml 的 [desktop] localeOverride”，本脚本只负责刷新页面，
 *   让 addScriptToEvaluateOnNewDocument 注册的 i18n-bootstrap 在新文档中
 *   先于应用脚本执行。
 *
 * 期望：
 *   表达式型 IIFE，return 一个 JSON 字符串；随后调用 location.reload()。
 *   Licensed under the MIT License（本文件为本仓库原创实现）。
 */
(function () {
  var state = null;
  try { state = window.__codexZhI18nState || null; } catch (_) {}
  var result = {
    status: 'ok',
    action: 'reload',
    href: String(location.href || ''),
    reloadDelayMs: 350,
    i18nState: state,
    requestedAt: Date.now()
  };
  try { window.__codexZhReloadRequested = true; } catch (_) {}
  window.setTimeout(function () {
    try { window.location.reload(); } catch (_) {}
  }, 350);
  return JSON.stringify(result);
})()
