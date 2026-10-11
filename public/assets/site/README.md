# 下载站前端资源

本目录保存下载站页面共用的样式和前端脚本。站点 HTML 页面由项目构建脚本生成；本目录不包含固件或独立页面。

## 文件说明

| 文件        | 用途                                                       |
| ----------- | ---------------------------------------------------------- |
| `base.css`  | 站点基础样式                                               |
| `site.css`  | 下载站页面布局和视觉样式                                   |
| `site.js`   | 中英文界面切换，记住用户选择并通知页面组件                 |
| `readme.js` | 渐进式渲染 README 内容，并为代码块增加高亮、行号和复制按钮 |

`site.js` 默认使用中文；用户切换语言后，选择会保存在浏览器 `localStorage`，并在站点页面间生效。页面文案使用 `data-zh` / `data-en` 属性。README 渲染依赖页面引入的 Markdown 与代码高亮库；如果加载失败，保留页面已有的服务端内容。

站点标题、描述、上游样式表等配置见 [`config/site.json`](https://github.com/Shuery-Shuai/RouterFirmware/blob/main/config/site.json)，页面生成器位于 [`scripts/`](https://github.com/Shuery-Shuai/RouterFirmware/tree/main/scripts)。

## 修改说明

修改样式或脚本后，应检查下载站首页、固件列表页和 README 展示块，并验证中文/英文切换、窄屏布局及脚本加载失败时的回退效果。
