// 主题管理系统

class ThemeManager {
  constructor() {
    this.themes = {
      light: {
        name: '浅色',
        icon: '☀️'
      },
      dark: {
        name: '深色',
        icon: '🌙'
      },
      auto: {
        name: '跟随系统',
        icon: '🔄'
      }
    };

    // 从 localStorage 读取用户设置
    this.currentTheme = localStorage.getItem('theme') || 'auto';

    this.customBackground = JSON.parse(localStorage.getItem('customBackground') || JSON.stringify({
      type: 'none', // 'none', 'color', 'image', 'video'
      value: '',
      opacity: 1
    }));

    this.init();
  }

  init() {
    this.createThemeSwitcher();
    this.applyTheme(this.currentTheme);
    this.applyCustomBackground();

    // 监听系统主题变化（仅在 auto 模式下）
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
      if (this.currentTheme === 'auto') {
        this.applyTheme('auto');
      }
    });
  }

  createThemeSwitcher() {
    const switcher = document.createElement('div');
    switcher.className = 'theme-switcher';
    switcher.innerHTML = `
      ${Object.entries(this.themes).map(([key, theme]) => `
        <button class="theme-btn" data-theme="${key}" title="${theme.name}主题">
          <span>${theme.icon}</span>
          <span>${theme.name}</span>
        </button>
      `).join('')}
      <button class="theme-btn" data-action="settings" title="主题设置">
        <span>⚙️</span>
        <span>设置</span>
      </button>
    `;

    document.body.appendChild(switcher);

    // 绑定按钮点击事件
    switcher.querySelectorAll('.theme-btn[data-theme]').forEach(btn => {
      btn.addEventListener('click', () => {
        this.setTheme(btn.dataset.theme);
      });
    });

    // 设置按钮
    switcher.querySelector('[data-action="settings"]').addEventListener('click', () => {
      this.openSettings();
    });

    this.updateSwitcherUI();
  }

  setTheme(theme) {
    this.currentTheme = theme;
    localStorage.setItem('theme', theme);
    this.applyTheme(theme);
    this.updateSwitcherUI();
  }

  applyTheme(theme) {
    let actualTheme = theme;

    if (theme === 'auto') {
      // 跟随系统主题
      const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
      actualTheme = prefersDark ? 'dark' : 'light';
    }

    document.documentElement.setAttribute('data-theme', actualTheme);
  }

  updateSwitcherUI() {
    document.querySelectorAll('.theme-btn[data-theme]').forEach(btn => {
      btn.classList.toggle('active', btn.dataset.theme === this.currentTheme);
    });
  }

  openSettings() {
    const modal = document.createElement('div');
    modal.className = 'theme-settings-modal';
    modal.innerHTML = `
      <div class="theme-settings-overlay"></div>
      <div class="theme-settings-content">
        <div class="theme-settings-header">
          <h2>主题设置</h2>
          <button class="close-btn">×</button>
        </div>
        <div class="theme-settings-body">
          <!-- 自定义背景 -->
          <div class="setting-section">
            <h3>自定义背景</h3>
            <div class="setting-item">
              <label>背景类型：</label>
              <select id="bgType">
                <option value="none">无</option>
                <option value="color">纯色</option>
                <option value="image">图片</option>
                <option value="video">视频</option>
              </select>
            </div>
            <div class="setting-item" id="bgValueContainer">
              <label id="bgValueLabel">背景值：</label>
              <input type="text" id="bgValue" placeholder="输入颜色/URL">
            </div>
            <div class="setting-item">
              <label>透明度：</label>
              <input type="range" id="bgOpacity" min="0" max="1" step="0.1" value="${this.customBackground.opacity}">
              <span id="opacityValue">${this.customBackground.opacity}</span>
            </div>
          </div>

          <div class="setting-actions">
            <button class="btn-save">保存</button>
            <button class="btn-reset">重置</button>
            <button class="btn-cancel">取消</button>
          </div>
        </div>
      </div>
    `;

    document.body.appendChild(modal);

    // 设置当前值
    modal.querySelector('#bgType').value = this.customBackground.type;
    modal.querySelector('#bgValue').value = this.customBackground.value;

    // 背景类型变化时更新标签
    const bgTypeSelect = modal.querySelector('#bgType');
    const bgValueLabel = modal.querySelector('#bgValueLabel');
    const bgValueInput = modal.querySelector('#bgValue');

    bgTypeSelect.addEventListener('change', () => {
      const type = bgTypeSelect.value;
      if (type === 'none') {
        modal.querySelector('#bgValueContainer').style.display = 'none';
      } else {
        modal.querySelector('#bgValueContainer').style.display = 'flex';
        if (type === 'color') {
          bgValueLabel.textContent = '颜色：';
          bgValueInput.type = 'color';
          bgValueInput.placeholder = '';
        } else if (type === 'image') {
          bgValueLabel.textContent = '图片 URL：';
          bgValueInput.type = 'text';
          bgValueInput.placeholder = 'https://example.com/image.jpg';
        } else if (type === 'video') {
          bgValueLabel.textContent = '视频 URL：';
          bgValueInput.type = 'text';
          bgValueInput.placeholder = 'https://example.com/video.mp4';
        }
      }
    });
    bgTypeSelect.dispatchEvent(new Event('change'));

    // 透明度滑块
    const opacitySlider = modal.querySelector('#bgOpacity');
    const opacityValue = modal.querySelector('#opacityValue');
    opacitySlider.addEventListener('input', () => {
      opacityValue.textContent = opacitySlider.value;
    });

    // 关闭按钮
    const closeModal = () => modal.remove();
    modal.querySelector('.close-btn').addEventListener('click', closeModal);
    modal.querySelector('.theme-settings-overlay').addEventListener('click', closeModal);
    modal.querySelector('.btn-cancel').addEventListener('click', closeModal);

    // 保存按钮
    modal.querySelector('.btn-save').addEventListener('click', () => {
      this.customBackground = {
        type: modal.querySelector('#bgType').value,
        value: modal.querySelector('#bgValue').value,
        opacity: parseFloat(modal.querySelector('#bgOpacity').value)
      };

      localStorage.setItem('customBackground', JSON.stringify(this.customBackground));

      this.applyTheme(this.currentTheme);
      this.applyCustomBackground();
      closeModal();
    });

    // 重置按钮
    modal.querySelector('.btn-reset').addEventListener('click', () => {
      if (confirm('确定要重置所有主题设置吗？')) {
        localStorage.removeItem('theme');
        localStorage.removeItem('customBackground');
        location.reload();
      }
    });
  }

  applyCustomBackground() {
    const { type, value, opacity } = this.customBackground;

    // 移除之前的视频元素
    const oldVideo = document.getElementById('bg-video');
    if (oldVideo) oldVideo.remove();

    document.body.removeAttribute('data-bg-type');

    if (type === 'none') {
      document.documentElement.style.setProperty('--body-bg-image', 'none');
      document.documentElement.style.setProperty('--body-bg-opacity', '1');
    } else if (type === 'color') {
      document.documentElement.style.setProperty('--body-bg', value);
      document.documentElement.style.setProperty('--body-bg-image', 'none');
    } else if (type === 'image') {
      document.documentElement.style.setProperty('--body-bg-image', `url("${value}")`);
      document.documentElement.style.setProperty('--body-bg-opacity', opacity);
    } else if (type === 'video') {
      const video = document.createElement('video');
      video.id = 'bg-video';
      video.autoplay = true;
      video.loop = true;
      video.muted = true;
      video.playsInline = true;
      video.src = value;
      document.body.prepend(video);
      document.body.setAttribute('data-bg-type', 'video');
      document.documentElement.style.setProperty('--body-bg-opacity', opacity);
    }
  }
}

// 初始化主题管理器
document.addEventListener('DOMContentLoaded', () => {
  window.themeManager = new ThemeManager();
});
