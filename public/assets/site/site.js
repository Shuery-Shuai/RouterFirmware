/* 站点语言切换（中 / 英）
 *
 * 约定（见 scripts/site_i18n.py）：
 *   - 双语节点：<el data-zh="中文" data-en="English">中文</el>
 *   - 可切换标题：<title data-zh="…" data-en="…">English</title>
 *   - 切换入口：#lang-toggle
 *
 * 行为：
 *   - 首次访问默认中文；选择写入 localStorage，跨页面生效
 *   - 切换时同步 <html lang>、<html data-lang>、<title>，并派发 langchange 事件
 *     （readme.js 之类的组件据此更新自己的文案）
 */
(function () {
  'use strict';

  var STORAGE_KEY = 'site-lang';
  var toggle = document.getElementById('lang-toggle');
  var nodes = document.querySelectorAll('[data-zh][data-en]');

  function stored() {
    try {
      return localStorage.getItem(STORAGE_KEY) === 'en' ? 'en' : 'zh';
    } catch (err) {
      return 'zh';
    }
  }

  function apply(lang) {
    document.documentElement.lang = lang === 'en' ? 'en' : 'zh-CN';
    document.documentElement.setAttribute('data-lang', lang);

    Array.prototype.forEach.call(nodes, function (el) {
      var text = el.getAttribute('data-' + lang);
      if (text === null) return;
      // data-html：值里含 <code> 等内联标记，必须用 innerHTML；其余用 textContent 更安全
      if (el.hasAttribute('data-html')) el.innerHTML = text;
      else el.textContent = text;
    });

    var title = document.querySelector('title[data-zh][data-en]');
    if (title) {
      var titleText = title.getAttribute('data-' + lang);
      if (titleText) document.title = titleText;
    }

    // 图标按钮：只切换 title / aria-label（目标语言）；不能写 textContent，
    // 否则会把内联 SVG 图标一起抹掉
    if (toggle) {
      var target = lang === 'en' ? '中文' : 'English';
      toggle.setAttribute('title', target);
      toggle.setAttribute('aria-label', target);
    }

    try {
      localStorage.setItem(STORAGE_KEY, lang);
    } catch (err) {
      /* 隐私模式下写入失败：忽略，仅本次会话生效 */
    }

    document.dispatchEvent(new CustomEvent('langchange', { detail: { lang: lang } }));
  }

  if (toggle) {
    toggle.addEventListener('click', function (event) {
      event.preventDefault();
      apply(stored() === 'zh' ? 'en' : 'zh');
    });
  }

  apply(stored());
})();
