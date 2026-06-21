// 文件浏览器主脚本

const state = { data: null, currentPath: '', searchQuery: '' };

// 格式化文件大小
function formatSize(bytes) {
  if (!bytes) return '-';
  if (bytes < 1024) return bytes + 'B';
  if (bytes < 1048576) return (bytes / 1024).toFixed(1) + 'K';
  if (bytes < 1073741824) return (bytes / 1048576).toFixed(1) + 'M';
  return (bytes / 1073741824).toFixed(2) + 'G';
}

// 格式化日期
function formatDate(timestamp) {
  if (!timestamp) return '-';
  const d = new Date(timestamp * 1000);
  return d.toLocaleString('zh-CN');
}

// 复制到剪贴板
function copyToClipboard(text, btn) {
  navigator.clipboard.writeText(text).then(() => {
    const orig = btn.textContent;
    btn.textContent = '✓';
    setTimeout(() => btn.textContent = orig, 1000);
  });
}

// 获取文件图标
function getIcon(item) {
  if (item.type === 'dir') return '📁';
  const name = item.name.toLowerCase();
  if (name.match(/\.(bin|img|iso)$/)) return '💿';
  if (name.match(/\.(tar|gz|xz|zip|7z)$/)) return '🗄️';
  if (name.match(/\.(txt|md|log)$/)) return '📄';
  if (name.match(/\.config$/)) return '⚙️';
  return '📄';
}

// 高亮搜索关键词
function highlightText(text, query) {
  if (!query) return text;
  const regex = new RegExp('(' + query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + ')', 'gi');
  return text.replace(regex, '<span class="highlight">$1</span>');
}

// 搜索文件（全局）
function searchFilesGlobal(query) {
  if (!query.trim()) {
    return null;
  }

  const lowerQuery = query.toLowerCase();
  const results = state.data.items.filter(item => {
    return item.name.toLowerCase().includes(lowerQuery) ||
           item.path.toLowerCase().includes(lowerQuery);
  });

  return results.sort((a, b) => {
    if (a.type !== b.type) return a.type === 'dir' ? -1 : 1;
    return a.path.localeCompare(b.path);
  });
}

// 搜索文件（当前目录及子目录）
function searchFilesCurrent(query, currentPath) {
  if (!query.trim()) {
    return null;
  }

  const lowerQuery = query.toLowerCase();
  const pathPrefix = currentPath ? currentPath + '/' : '';

  const results = state.data.items.filter(item => {
    const matchesQuery = item.name.toLowerCase().includes(lowerQuery) ||
                        item.path.toLowerCase().includes(lowerQuery);
    const inCurrentPath = currentPath === '' || item.path.startsWith(pathPrefix);
    return matchesQuery && inCurrentPath;
  });

  return results.sort((a, b) => {
    if (a.type !== b.type) return a.type === 'dir' ? -1 : 1;
    return a.path.localeCompare(b.path);
  });
}

// 渲染面包屑导航
function renderBreadcrumb(path) {
  let html = '<a href="/" onclick="navigate(\'\', event)">首页</a>';

  if (path) {
    const parts = path.split('/');
    let currentPath = '';
    parts.forEach((part, idx) => {
      currentPath += (idx > 0 ? '/' : '') + part;
      const encodedPath = currentPath;
      html += ` / <a href="/${encodedPath}" onclick="navigate('${encodedPath}', event)">${part}</a>`;
    });
  }

  document.getElementById('breadcrumb').innerHTML = html;
}

// 渲染搜索结果
function renderSearchResults(results, query, scope) {
  const scopeText = scope === 'global' ? '全局' : '当前目录';
  document.getElementById('breadcrumb').innerHTML = `搜索结果（${scopeText}）`;
  const searchInfo = document.getElementById('searchInfo');
  searchInfo.innerHTML = `找到 ${results.length} 个结果`;
  searchInfo.classList.add('active');

  // 隐藏 README 容器
  document.getElementById('readme').style.display = 'none';

  if (results.length === 0) {
    document.getElementById('content').innerHTML = '<p>未找到匹配的文件或目录</p>';
    return;
  }

  let html = `<table>
    <thead>
      <tr>
        <th class="n">路径</th>
        <th class="s">大小</th>
        <th class="h">SHA256</th>
        <th class="d">修改时间</th>
      </tr>
    </thead>
    <tbody>`;

  results.forEach(item => {
    const icon = getIcon(item);
    const displayPath = highlightText(item.path, query);
    const link = item.type === 'dir'
      ? `<a href="/${item.path}" onclick="navigate('${item.path}', event)">${displayPath}/</a>`
      : `<a href="/${item.path}" target="_blank">${displayPath}</a>`;

    const size = item.type === 'dir' ? '-' : formatSize(item.size);
    const hash = item.sha256
      ? `<span class="hash">${item.sha256.slice(0, 8)}...</span><span class="copy-btn" onclick="copyToClipboard('${item.sha256}', this)">📋</span>`
      : '-';
    const date = formatDate(item.mtime);

    html += `<tr>
      <td class="n">${icon} ${link}</td>
      <td class="s">${size}</td>
      <td class="h">${hash}</td>
      <td class="d">${date}</td>
    </tr>`;
  });

  html += '</tbody></table>';
  document.getElementById('content').innerHTML = html;
}

// 加载并渲染 README.md
function loadReadme(path) {
  const readmePath = path ? `/${path}/README.md` : '/README.md';
  const readmeContainer = document.getElementById('readme');

  fetch(readmePath)
    .then(response => {
      if (!response.ok) throw new Error('README not found');
      return response.text();
    })
    .then(markdown => {
      // 检查依赖是否加载
      if (typeof window.markdownit === 'undefined') {
        console.error('markdown-it not loaded');
        readmeContainer.innerHTML = '<pre>' + markdown + '</pre>';
        readmeContainer.style.display = 'block';
        return;
      }

      // 初始化 markdown-it
      const md = window.markdownit({
        html: true,
        linkify: true,
        typographer: true,
        highlight: function (str, lang) {
          if (typeof hljs !== 'undefined' && lang && hljs.getLanguage(lang)) {
            try {
              return hljs.highlight(str, { language: lang }).value;
            } catch (__) {}
          }
          return ''; // 使用默认转义
        }
      });

      // 添加 KaTeX 插件
      if (typeof window.markdownitKatex !== 'undefined') {
        md.use(window.markdownitKatex);
      }

      // 渲染 markdown
      readmeContainer.innerHTML = md.render(markdown);
      readmeContainer.style.display = 'block';

      // 为代码块添加复制按钮
      addCopyButtonsToCodeBlocks(readmeContainer);
    })
    .catch((err) => {
      console.log('README not found:', err.message);
      readmeContainer.style.display = 'none';
    });
}

// 为代码块添加复制按钮
function addCopyButtonsToCodeBlocks(container) {
  const codeBlocks = container.querySelectorAll('pre code');

  codeBlocks.forEach(codeBlock => {
    const pre = codeBlock.parentElement;

    // 避免重复添加
    if (pre.querySelector('.copy-code-btn')) return;

    // 创建复制按钮
    const copyButton = document.createElement('button');
    copyButton.className = 'copy-code-btn';
    copyButton.textContent = '复制';
    copyButton.setAttribute('aria-label', '复制代码');

    // 复制功能
    copyButton.addEventListener('click', () => {
      const code = codeBlock.textContent;
      navigator.clipboard.writeText(code).then(() => {
        copyButton.textContent = '已复制';
        copyButton.classList.add('copied');
        setTimeout(() => {
          copyButton.textContent = '复制';
          copyButton.classList.remove('copied');
        }, 2000);
      }).catch(err => {
        console.error('复制失败:', err);
        copyButton.textContent = '失败';
        setTimeout(() => {
          copyButton.textContent = '复制';
        }, 2000);
      });
    });

    // 将 pre 设为相对定位，以便按钮绝对定位
    pre.style.position = 'relative';
    pre.appendChild(copyButton);
  });
}

// 渲染文件列表
function renderFiles(path) {
  state.currentPath = path;
  state.searchQuery = '';
  document.getElementById('searchInput').value = '';
  const searchInfo = document.getElementById('searchInfo');
  searchInfo.innerHTML = '';
  searchInfo.classList.remove('active');
  renderBreadcrumb(path);
  loadReadme(path);

  // 过滤当前路径的项目
  const items = state.data.items.filter(item => {
    if (!path) return !item.path.includes('/');
    return item.path.startsWith(path + '/') &&
           item.path.slice(path.length + 1).indexOf('/') === -1;
  });

  if (items.length === 0) {
    document.getElementById('content').innerHTML = '<p>此目录为空</p>';
    return;
  }

  // 排序：目录在前
  items.sort((a, b) => {
    if (a.type !== b.type) return a.type === 'dir' ? -1 : 1;
    return a.name.localeCompare(b.name);
  });

  let html = `<table>
    <thead>
      <tr>
        <th class="n">名称</th>
        <th class="s">大小</th>
        <th class="h">SHA256</th>
        <th class="d">修改时间</th>
      </tr>
    </thead>
    <tbody>`;

  // 上级目录
  if (path) {
    const parentPath = path.split('/').slice(0, -1).join('/');
    html += `<tr><td class="n"><a href="/${parentPath}" onclick="navigate('${parentPath}', event)">↩️ 上级目录</a></td><td class="s">-</td><td class="h">-</td><td class="d">-</td></tr>`;
  }

  items.forEach(item => {
    const icon = getIcon(item);
    const name = item.name + (item.type === 'dir' ? '/' : '');
    const link = item.type === 'dir'
      ? `<a href="/${item.path}" onclick="navigate('${item.path}', event)">${name}</a>`
      : `<a href="/${item.path}" target="_blank">${name}</a>`;

    const size = item.type === 'dir' ? '-' : formatSize(item.size);
    const hash = item.sha256
      ? `<span class="hash">${item.sha256.slice(0, 8)}...</span><span class="copy-btn" onclick="copyToClipboard('${item.sha256}', this)">📋</span>`
      : '-';
    const date = formatDate(item.mtime);

    html += `<tr>
      <td class="n">${icon} ${link}</td>
      <td class="s">${size}</td>
      <td class="h">${hash}</td>
      <td class="d">${date}</td>
    </tr>`;
  });

  html += '</tbody></table>';
  document.getElementById('content').innerHTML = html;
}

// 处理搜索
function handleSearch(scope) {
  const query = document.getElementById('searchInput').value.trim();
  state.searchQuery = query;

  if (!query) {
    renderFiles(state.currentPath);
    return;
  }

  const results = scope === 'global'
    ? searchFilesGlobal(query)
    : searchFilesCurrent(query, state.currentPath);

  if (results) {
    renderSearchResults(results, query, scope);
  }
}

// 导航
function navigate(path, event) {
  if (event) {
    event.preventDefault();
  }
  window.history.pushState({ path }, '', '/' + path);
  renderFiles(path);
}

// 处理浏览器前进/后退
function handlePopState(event) {
  const path = event.state ? event.state.path : getPathFromURL();
  renderFiles(path);
}

// 从 URL 获取路径
function getPathFromURL() {
  // GitHub Pages 404.html 重定向支持
  const redirectPath = sessionStorage.getItem('redirectPath');
  if (redirectPath) {
    sessionStorage.removeItem('redirectPath');
    return redirectPath.slice(1); // 去掉开头的 /
  }
  const path = window.location.pathname.slice(1);
  return path;
}

// 初始化
document.addEventListener('DOMContentLoaded', () => {
  // 加载数据
  fetch('/assets/web/data/index.json')
    .then(r => r.json())
    .then(data => {
      state.data = data;
      const initialPath = getPathFromURL();
      window.history.replaceState({ path: initialPath }, '', '/' + initialPath);
      renderFiles(initialPath);
      window.addEventListener('popstate', handlePopState);

      // 绑定搜索事件
      const searchInput = document.getElementById('searchInput');
      const searchCurrentBtn = document.getElementById('searchCurrentBtn');
      const searchGlobalBtn = document.getElementById('searchGlobalBtn');

      // 回车默认搜索当前目录
      searchInput.addEventListener('keyup', (e) => {
        if (e.key === 'Enter') {
          handleSearch('current');
        } else if (e.key === 'Escape') {
          searchInput.value = '';
          renderFiles(state.currentPath);
        }
      });

      // 按钮点击事件
      searchCurrentBtn.addEventListener('click', () => handleSearch('current'));
      searchGlobalBtn.addEventListener('click', () => handleSearch('global'));
    })
    .catch(err => {
      document.getElementById('content').innerHTML =
        `<div class="error">加载失败: ${err.message}</div>`;
    });
});
