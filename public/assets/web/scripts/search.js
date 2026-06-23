// 全局变量
let allData = [];
let filteredData = [];
const ITEMS_PER_PAGE = 100;
let currentPage = 1;

// 排序相关
let sortBy = 'name';  // 默认按文件名排序
let sortOrder = 'asc'; // 升序：asc，降序：desc

// 初始化
document.addEventListener("DOMContentLoaded", async () => {
  try {
    await loadData();
    setupSearch();
    applySort();
    renderTable();
  } catch (error) {
    showError("无法加载索引数据: " + error.message);
  }
});

// 加载 JSON 数据
async function loadData() {
  try {
    const response = await fetch("/assets/web/data/items.json");
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const data = await response.json();
    allData = data.files || [];

    // 更新页脚信息
    if (data.metadata) {
      const meta = data.metadata;
      document.getElementById("footerText").textContent =
        `由 ${meta.buildSource} 生成于 ${meta.generateTime}`;
      document.getElementById("repoText").innerHTML =
        `仓库地址: <a href="${meta.repositoryUrl}" target="_blank">${meta.repositoryDisplay}</a>`;
    }

    updateStats();
  } catch (error) {
    throw new Error("加载 items.json 失败: " + error.message);
  }
}

// 设置搜索输入
function setupSearch() {
  const searchInput = document.getElementById("searchInput");
  searchInput.addEventListener("input", (e) => {
    const query = e.target.value.toLowerCase();
    currentPage = 1;

    if (!query) {
      filteredData = allData.slice();
    } else {
      filteredData = allData.filter((item) => {
        const name = item.name.toLowerCase();
        const type = item.type.toLowerCase();
        const path = item.path.toLowerCase();
        return (
          name.includes(query) || type.includes(query) || path.includes(query)
        );
      });
    }

    applySort();
    updateStats();
    renderTable();
  });

  // 支持 URL 参数搜索
  const params = new URLSearchParams(window.location.search);
  const q = params.get("q");
  if (q) {
    searchInput.value = q;
    searchInput.dispatchEvent(new Event("input"));
  }
}

// 排序数据
function applySort() {
  const sortMap = {
    'name': (a, b) => a.name.localeCompare(b.name),
    'type': (a, b) => a.type.localeCompare(b.type),
    'size': (a, b) => {
      const aSize = parseSizeToBytes(a.size);
      const bSize = parseSizeToBytes(b.size);
      return aSize - bSize;
    },
    'date': (a, b) => new Date(a.date) - new Date(b.date),
    'path': (a, b) => a.path.localeCompare(b.path)
  };
  
  const compareFn = sortMap[sortBy];
  if (!compareFn) return;
  
  filteredData.sort(compareFn);
  
  // 如果是降序，反向排列
  if (sortOrder === 'desc') {
    filteredData.reverse();
  }
}

// 将大小字符串转换为字节数（用于排序）
function parseSizeToBytes(sizeStr) {
  const units = { 'B': 1, 'KB': 1024, 'MB': 1024**2, 'GB': 1024**3, 'TB': 1024**4 };
  const match = sizeStr.trim().match(/([\d.]+)\s*(\w+)/);
  if (!match) return 0;
  const value = parseFloat(match[1]);
  const unit = match[2];
  return value * (units[unit] || 1);
}

// 处理表头点击排序
function handleSort(column) {
  const columnMap = {
    'n': 'name',
    'm': 'type',
    's': 'size',
    'd': 'date',
    'p': 'path'
  };
  
  const newSortBy = columnMap[column];
  if (!newSortBy) return;
  
  // 如果点击同一列，切换排序方向；否则按升序排列
  if (sortBy === newSortBy) {
    sortOrder = sortOrder === 'asc' ? 'desc' : 'asc';
  } else {
    sortBy = newSortBy;
    sortOrder = 'asc';
  }
  
  currentPage = 1;
  applySort();
  renderTable();
}

// 更新统计信息
function updateStats() {
  const total = allData.length;
  const filtered = filteredData.length;
  const statsText = document.getElementById("statsText");

  if (!filteredData.length && allData.length) {
    statsText.textContent = `未找到匹配项 (总计: ${total} 个文件)`;
  } else {
    statsText.textContent = `显示 ${filtered} / ${total} 个文件`;
  }
}

// 渲染表格
function renderTable() {
  const content = document.getElementById("content");

  if (!filteredData.length) {
    if (allData.length) {
      content.innerHTML = '<div class="empty-state">😔 未找到匹配的文件</div>';
    } else {
      content.innerHTML = '<div class="empty-state">📭 没有文件数据</div>';
    }
    return;
  }

  // 计算分页
  const totalPages = Math.ceil(filteredData.length / ITEMS_PER_PAGE);
  const start = (currentPage - 1) * ITEMS_PER_PAGE;
  const end = Math.min(start + ITEMS_PER_PAGE, filteredData.length);
  const pageData = filteredData.slice(start, end);

  // 生成表头排序指示符
  const getSortIndicator = (column) => {
    if (sortBy === column) {
      return sortOrder === 'asc' ? '▲' : '▼';
    }
    return '';
  };

  // 构建表格
  let html =
    '<div class="table-wrapper"><table><thead><tr>' +
    `<th class="n" onclick="handleSort('n')" style="cursor: pointer;">文件名 ${getSortIndicator('name')}</th>` +
    `<th class="m" onclick="handleSort('m')" style="cursor: pointer;">类型 ${getSortIndicator('type')}</th>` +
    `<th class="s" onclick="handleSort('s')" style="cursor: pointer;">大小 ${getSortIndicator('size')}</th>` +
    '<th class="h">SHA256</th>' +
    `<th class="d" onclick="handleSort('d')" style="cursor: pointer;">修改日期 ${getSortIndicator('date')}</th>` +
    `<th class="p" onclick="handleSort('p')" style="cursor: pointer;">路径 ${getSortIndicator('path')}</th>` +
    "</tr></thead><tbody>";

  for (const item of pageData) {
    const sha256Display =
      item.sha256 === "-"
        ? "-"
        : `<span title="${item.sha256}">${item.sha256.substring(0, 8)}...</span><span class="copy-btn" onclick="copySHA256('${item.sha256}', this)" title="复制完整 SHA256">📋</span>`;

    html += `<tr>
      <td class="n">${item.icon} <a href="${item.url}">${item.name}</a></td>
      <td class="m">${item.type}</td>
      <td class="s">${item.size}</td>
      <td class="sh">${sha256Display}</td>
      <td class="d">${item.date}</td>
      <td class="p" data-full="${item.path}">${item.path}</td>
    </tr>`;
  }

  html += "</tbody></table></div>";

  // 添加分页控制
  if (totalPages > 1) {
    html += '<div class="pagination">';

    if (currentPage > 1) {
      html += `<button onclick="goToPage(1)">首页</button> `;
      html += `<button onclick="goToPage(${currentPage - 1})">上一页</button> `;
    }

    html += `<span style="color: #666;">第 ${currentPage} / ${totalPages} 页</span> `;

    if (currentPage < totalPages) {
      html += `<button onclick="goToPage(${currentPage + 1})">下一页</button> `;
      html += `<button onclick="goToPage(${totalPages})">末页</button>`;
    }

    html += "</div>";
  }

  content.innerHTML = html;
  applyPathTruncation();
}

// 分页控制
function goToPage(page) {
  const totalPages = Math.ceil(filteredData.length / ITEMS_PER_PAGE);
  if (page >= 1 && page <= totalPages) {
    currentPage = page;
    renderTable();
    window.scrollTo(0, 0);
  }
}

// 显示错误信息
function showError(message) {
  const content = document.getElementById("content");
  content.innerHTML = `<div class="error">❌ ${message}</div>`;
}

// 复制 SHA256 到剪贴板
function copySHA256(sha256, element) {
  navigator.clipboard
    .writeText(sha256)
    .then(() => {
      // 显示复制成功提示
      const originalText = element.textContent;
      element.textContent = "✅";
      element.style.opacity = "1";
      setTimeout(() => {
        element.textContent = originalText;
      }, 1500);
    })
    .catch((err) => {
      console.error("复制失败:", err);
      element.textContent = "❌";
      setTimeout(() => {
        element.textContent = "📋";
      }, 1500);
    });
}

// 计算字符串的显示宽度（汉字 = 2，其他 = 1）
function getStringWidth(str) {
  let width = 0;
  for (let i = 0; i < str.length; i++) {
    const char = str.charCodeAt(i);
    // 检查是否为 CJK 字符（汉字、日文、韩文等）
    if (
      (char >= 0x4e00 && char <= 0x9fff) || // CJK Unified Ideographs
      (char >= 0x3400 && char <= 0x4dbf) || // CJK Extension A
      (char >= 0x20000 && char <= 0x2a6df) || // CJK Extension B
      (char >= 0x2a700 && char <= 0x2b73f) || // CJK Extension C
      (char >= 0x3040 && char <= 0x309f) || // 日文平假名
      (char >= 0x30a0 && char <= 0x30ff) || // 日文片假名
      (char >= 0xac00 && char <= 0xd7af)
    ) {
      // 韩文
      width += 2;
    } else {
      width += 1;
    }
  }
  return width;
}

// 根据宽度截断字符串
function truncateStringByWidth(str, maxWidth) {
  let width = 0;
  let result = "";
  for (let i = 0; i < str.length; i++) {
    const char = str[i];
    const charCode = str.charCodeAt(i);
    let charWidth = 1;

    // CJK 字符占 2 个单位
    if (
      (charCode >= 0x4e00 && charCode <= 0x9fff) ||
      (charCode >= 0x3400 && charCode <= 0x4dbf) ||
      (charCode >= 0x20000 && charCode <= 0x2a6df) ||
      (charCode >= 0x2a700 && charCode <= 0x2b73f) ||
      (charCode >= 0x3040 && charCode <= 0x309f) ||
      (charCode >= 0x30a0 && charCode <= 0x30ff) ||
      (charCode >= 0xac00 && charCode <= 0xd7af)
    ) {
      charWidth = 2;
    }

    if (width + charWidth > maxWidth) {
      break;
    }
    result += char;
    width += charWidth;
  }
  return result;
}

// 智能截断路径：保留开头和结尾，中间用 …… 替代
function truncatePath(path, maxWidth, keyword) {
  const currentWidth = getStringWidth(path);
  if (currentWidth <= maxWidth) return path;

  // 有搜索关键词时，优先保证关键词完整显示
  if (keyword && keyword.length > 0) {
    const idx = path.toLowerCase().indexOf(keyword.toLowerCase());
    if (idx !== -1) {
      const context = 10; // 关键词前后保留的字符数
      let start = Math.max(0, idx - context);
      let end = Math.min(path.length, idx + keyword.length + context);

      // 调整 start 和 end，确保总宽度不超过 maxWidth
      let prefix = path.substring(0, start);
      let content = path.substring(start, end);
      let suffix = path.substring(end);

      const contentWidth = getStringWidth(content);
      if (contentWidth <= maxWidth) {
        return (
          (start > 0 ? "…" : "") + content + (end < path.length ? "…" : "")
        );
      }

      // 空间不够时，缩短内容
      const targetWidth = Math.max(10, maxWidth - 2); // 保留空间给 …
      content = truncateStringByWidth(content, targetWidth);
      return "…" + content + "…";
    }
  }

  // 无关键词时的默认截断：保留第一段目录 + 最后两段
  const parts = path.split("/").filter((p) => p.length > 0);
  if (parts.length <= 3) return path; // 路径较短，不截断

  // 尝试保留：/第一段/……/倒数第二段/最后一段
  const first = parts[0];
  const secondLast = parts[parts.length - 2];
  const last = parts[parts.length - 1];

  // 尽可能保留最完整的形式，优先级：
  // 1. /first/……/secondLast/last
  // 2. /first/……/last
  // 3. 截断各部分

  let result = "/" + first + "/……/" + secondLast + "/" + last;
  let resultWidth = getStringWidth(result);

  if (resultWidth <= maxWidth) {
    return result;
  }

  // 尝试移除倒数第二段
  result = "/" + first + "/……/" + last;
  resultWidth = getStringWidth(result);

  if (resultWidth <= maxWidth) {
    return result;
  }

  // 如果还是太宽，逐步缩短 first 和 last
  let shortFirst = first;
  let shortLast = last;

  while (
    resultWidth > maxWidth &&
    (shortFirst.length > 3 || shortLast.length > 3)
  ) {
    // 优先缩短长的那个
    if (
      getStringWidth(shortFirst) >= getStringWidth(shortLast) &&
      shortFirst.length > 3
    ) {
      shortFirst = shortFirst.substring(0, shortFirst.length - 1);
    } else if (shortLast.length > 3) {
      shortLast = shortLast.substring(0, shortLast.length - 1);
    } else if (shortFirst.length > 3) {
      shortFirst = shortFirst.substring(0, shortFirst.length - 1);
    }

    result = "/" + shortFirst + "/……/" + shortLast;
    resultWidth = getStringWidth(result);
  }

  return result;
}

// 动态调整路径截断
function applyPathTruncation() {
  const searchInput = document.getElementById("searchInput");
  const keyword = searchInput ? searchInput.value : "";
  const cells = document.querySelectorAll("td.p");
  cells.forEach((cell) => {
    const fullPath = cell.getAttribute("data-full") || cell.textContent;
    cell.setAttribute("title", fullPath);

    // 获取单元格实际宽度（像素）
    const cellWidth = cell.clientWidth;

    // 根据宽度估算最大显示宽度（单位：汉字=2，字母=1）
    // 平均字符在表格中占用约 8px（考虑间距）
    // 汉字 ≈ 16px，字母 ≈ 8px，所以平均比例 1.5:1
    // 为了安全起见，假设平均 6px 一个单位宽度
    const avgPixelPerUnit = 6;
    const maxDisplayWidth = Math.max(
      12,
      Math.floor(cellWidth / avgPixelPerUnit),
    );

    const truncated = truncatePath(fullPath, maxDisplayWidth, keyword);
    cell.textContent = truncated;
  });
}

// 窗口加载和调整时重新计算路径
window.addEventListener("resize", function () {
  applyPathTruncation();
});
