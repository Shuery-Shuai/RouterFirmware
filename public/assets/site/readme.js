/* README 说明块的客户端渲染（渐进增强）
 *
 * 设计：
 *   - Markdown 渲染用社区标准库 markdown-it，代码高亮用 highlight.js（页面以 CDN + SRI 引入）
 *   - 本脚本只做三件事：取 README.md、交给 markdown-it、给代码块补「行号 + 复制按钮」
 *   - 逐行高亮（hljs.highlight 每行单独调用），避免跨行标签在分行时被拆坏
 *   - 文案跟随站点语言（site.js 派发的 langchange 事件）
 *   - 任一步失败都保留服务端已渲染的兜底内容，绝不把块清空
 */
(function () {
  'use strict';

  var LABELS = {
    zh: { copy: '复制', copied: '已复制' },
    en: { copy: 'Copy', copied: 'Copied' }
  };

  var blocks = document.querySelectorAll('.readme[data-readme-src]');
  if (!blocks.length || typeof window.markdownit !== 'function' || typeof window.hljs !== 'object') {
    return;
  }

  var md = window.markdownit({ html: false, linkify: true });

  function lang() {
    return document.documentElement.getAttribute('data-lang') === 'en' ? 'en' : 'zh';
  }

  function languageOf(codeEl) {
    var match = /language-([A-Za-z0-9_+-]+)/.exec(codeEl.className || '');
    return match ? match[1].toLowerCase() : '';
  }

  function escapeHtml(text) {
    return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  function highlightLine(line, codeLang) {
    if (!codeLang || !window.hljs.getLanguage(codeLang)) return escapeHtml(line);
    try {
      return window.hljs.highlight(line, { language: codeLang, ignoreIllegals: true }).value;
    } catch (err) {
      return escapeHtml(line);
    }
  }

  function decorate(root) {
    var pres = root.querySelectorAll('pre > code');
    Array.prototype.forEach.call(pres, function (code) {
      var codeLang = languageOf(code);
      var source = code.textContent.replace(/\n$/, '');
      var lines = source.split('\n');
      code.classList.add('hljs');
      // 行间不要真实换行：<pre> 的 white-space: pre 会把换行当成额外空行（行距翻倍）
      code.innerHTML = lines.map(function (line) {
        return '<span class="code-line">' + highlightLine(line, codeLang) + '</span>';
      }).join('');

      var pre = code.parentNode;
      if (pre.parentNode && pre.parentNode.classList.contains('code-block')) return;
      var wrapper = document.createElement('div');
      wrapper.className = 'code-block';
      pre.parentNode.insertBefore(wrapper, pre);
      wrapper.appendChild(pre);

      var button = document.createElement('button');
      button.type = 'button';
      button.className = 'copy-btn';
      button.textContent = LABELS[lang()].copy;
      button.addEventListener('click', function () {
        if (!navigator.clipboard) return;
        navigator.clipboard.writeText(source).then(function () {
          button.textContent = LABELS[lang()].copied;
          setTimeout(function () { button.textContent = LABELS[lang()].copy; }, 1200);
        });
      });
      wrapper.appendChild(button);
    });
  }

  Array.prototype.forEach.call(blocks, function (block) {
    var src = block.getAttribute('data-readme-src');
    if (!src) return;
    fetch(src, { cache: 'no-cache' })
      .then(function (response) {
        if (!response.ok) throw new Error('HTTP ' + response.status);
        return response.text();
      })
      .then(function (text) {
        block.innerHTML = md.render(text);
        decorate(block);
      })
      .catch(function () {
        /* 保持服务端兜底渲染 */
      });
  });

  // 语言切换时同步复制按钮文案
  document.addEventListener('langchange', function () {
    var label = LABELS[lang()].copy;
    Array.prototype.forEach.call(document.querySelectorAll('.readme .copy-btn'), function (button) {
      button.textContent = label;
    });
  });
})();
