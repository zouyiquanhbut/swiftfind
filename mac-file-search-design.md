# Mac 文件搜索软件设计方案

## 1. 产品定位

一款面向 macOS 的本地文件即时搜索工具，核心体验类似 Everything：

- 常驻后台、增量索引
- 输入即搜，毫秒级返回文件名结果
- 支持路径、扩展名、大小、时间、标签等筛选
- 以键盘操作为主，尽量不打断用户工作
- 默认本地运行，不上传文件名、路径或文件内容

暂定产品名：**SwiftFind**。

## 2. 目标与非目标

### 目标

1. 首次输入后快速显示结果，常见搜索目标在 100 ms 内返回。
2. 支持几十万至数百万个文件的索引和实时更新。
3. 支持 Finder 风格路径跳转、预览、复制路径、Reveal in Finder。
4. 在 macOS 权限模型下稳定工作，并清楚提示用户授权范围。
5. 不因索引而明显拖慢系统或耗尽电量。

### 非目标（MVP 阶段）

- 不做云端文件搜索。
- 不做完整内容搜索引擎。
- 不替代 Finder 的文件管理能力。
- 不默认索引系统受保护目录、外接盘全部内容。
- 不在第一版支持复杂的自然语言查询。

## 3. 用户与典型场景

### 目标用户

- 经常处理大量项目文件的开发者、设计师、研究人员
- 需要快速定位下载文件、截图、文档的普通 Mac 用户
- 不希望使用云端搜索或系统级遥测的隐私敏感用户

### 核心场景

1. `invoice 2024`：搜索文件名或路径中包含关键词的文件。
2. `type:pdf modified:7d`：查找最近一周修改的 PDF。
3. 选中结果按 Return：在 Finder 中打开。
4. 按 ⌘⇧P：复制完整路径。
5. 搜索后按 ⌘1/⌘2：切换列表和图标视图。
6. 外接硬盘插入后自动开始增量索引。

## 4. 产品形态

### 主入口

- 菜单栏图标
- 全局快捷键，例如 `⌥Space`
- 主窗口/浮层搜索框
- 可选：Finder 右键服务「使用 SwiftFind 搜索所在目录」

### 主界面

```text
┌──────────────────────────────────────────────┐
│ 🔍  搜索文件名、路径或输入筛选条件       ⌘K │
├──────────────────────────────────────────────┤
│ 12,438 个结果       [相关性 ▼] [列表/图标]   │
├──────────────────────────────────────────────┤
│ PDF  project/report.pdf                      │
│     ~/Documents/Project/report.pdf          │
│     2.4 MB · 昨天 14:32                     │
│                                              │
│ 文件夹 project                               │
│     ~/Documents/project                      │
└──────────────────────────────────────────────┘
```

### 结果卡片显示

- 文件类型图标
- 文件名高亮
- 父目录/完整路径
- 大小、修改时间
- Git 状态或 Finder 标签（后续版本）
- 结果来源卷名称

## 5. 查询语法设计

### 默认行为

不带操作符时，对文件名和路径进行分词匹配；默认支持前缀匹配、模糊匹配和多词 AND。

示例：

- `report`：匹配名称或路径含 report 的项目
- `report pdf`：同时匹配 report 和 pdf
- `"quarterly report"`：短语匹配
- `-backup`：排除含 backup 的结果

### MVP 操作符

| 操作符 | 示例 | 说明 |
|---|---|---|
| `type:` | `type:pdf` | 按扩展名或 UTI 查询 |
| `kind:` | `kind:folder` | 文件、文件夹、图片等 |
| `path:` | `path:~/Downloads` | 限定目录 |
| `name:` | `name:meeting` | 仅匹配文件名 |
| `size:` | `size:>100MB` | 大小比较 |
| `modified:` | `modified:7d` | 最近修改时间 |
| `created:` | `created:2024-01-01..2024-12-31` | 创建时间范围 |
| `volume:` | `volume:Work` | 限定磁盘卷 |

解析策略：先将查询拆成结构化过滤器和全文/前缀词，再生成 SQL 查询。无法识别的语法按普通文本处理，不应让搜索直接失败。

## 6. 技术选型建议

### 推荐技术栈

- 语言：Swift 5.10+
- UI：SwiftUI；若需要更成熟的高性能表格，可混用 AppKit
- 最低系统：macOS 13 Ventura；若只追求最新 API，可提高到 macOS 14
- 数据库：SQLite，使用系统库或 GRDB
- 文件监听：FSEvents
- 文件元数据：URL resource values、FileManager、UniformTypeIdentifiers
- 快速预览：Quick Look / QLPreviewPanel
- 打包：签名、Notarization、DMG 或 Sparkle 自动更新

### 为什么不直接依赖 Spotlight

Spotlight 可作为补充数据源，但不应作为唯一引擎：

- 索引范围与更新时间由系统控制，结果可预测性较弱。
- 自定义排序、精确增量状态和跨卷一致性不容易控制。
- 用户期望的是「应用自己的即时索引」。

可在后续版本加入 MDQuery 作为内容搜索或系统元数据补充。

## 7. 总体架构

```text
┌─────────────────────────────────────────────┐
│ UI Layer                                    │
│ SearchWindow / ResultList / Preview / Menu  │
└──────────────────────┬──────────────────────┘
                       │ Query API
┌──────────────────────▼──────────────────────┐
│ Search Service                              │
│ Parser → Query Planner → Ranker → Pager     │
└───────────────┬─────────────────┬───────────┘
                │                 │
       ┌────────▼────────┐ ┌────▼─────────────┐
       │ Index Store      │ │ Metadata Cache   │
       │ SQLite + FTS5    │ │ icon/type/size   │
       └────────┬─────────┘ └──────────────────┘
                │
       ┌────────▼─────────────────────────────┐
       │ Indexer                              │
       │ Initial Scanner + FSEvents Watcher   │
       └──────────────────────────────────────┘
```

建议拆成两个进程或两个清晰的模块：

- App：窗口、查询、预览、用户设置
- Indexer：后台索引任务、文件监听、数据库写入

MVP 可以先做成单 App + actor/串行索引队列，后续再拆分为 XPC 服务。

## 8. 数据模型

### `volumes`

```sql
CREATE TABLE volumes (
  id INTEGER PRIMARY KEY,
  volume_uuid TEXT UNIQUE NOT NULL,
  name TEXT NOT NULL,
  root_path TEXT NOT NULL,
  is_enabled INTEGER NOT NULL DEFAULT 1,
  last_scan_at REAL,
  last_event_id INTEGER
);
```

### `files`

```sql
CREATE TABLE files (
  id INTEGER PRIMARY KEY,
  volume_id INTEGER NOT NULL,
  path TEXT NOT NULL,
  normalized_name TEXT NOT NULL,
  parent_path TEXT NOT NULL,
  is_directory INTEGER NOT NULL,
  extension TEXT,
  uti TEXT,
  byte_size INTEGER,
  created_at REAL,
  modified_at REAL,
  file_id TEXT,
  content_hash TEXT,
  indexed_at REAL NOT NULL,
  UNIQUE(volume_id, path),
  FOREIGN KEY(volume_id) REFERENCES volumes(id)
);
```

### 文件名搜索索引

```sql
CREATE VIRTUAL TABLE file_search USING fts5(
  file_id UNINDEXED,
  name,
  path,
  tokenize = 'unicode61 remove_diacritics 2'
);
```

说明：路径和名称可以分别建字段，允许 `name:` 只查文件名。对前缀查询可使用 `term*`；模糊匹配不宜直接在 SQL 中做全表 `%term%`，应通过 FTS、候选集和应用层评分完成。

## 9. 索引流程

### 首次索引

1. 读取用户选择的目录或卷。
2. 将根目录加入扫描队列。
3. 使用目录枚举器批量读取 URL resource values。
4. 每批 500～2000 条写入 SQLite，避免每个文件一次事务。
5. UI 显示已处理数量、预计剩余时间和暂停按钮。
6. 索引优先处理目录名和常见文件类型；内容提取放到低优先级任务。

### 增量更新

1. FSEvents 监听卷或授权目录。
2. 收到路径变化后进入去重队列，短时间内合并同一路径事件。
3. 对新增/修改路径重新读取元数据。
4. 对删除路径删除数据库记录。
5. 对目录移动优先重扫该目录，必要时使用 fileID 辅助识别。
6. FSEvents 丢失或事件历史不可用时，执行受控的一致性扫描。

### 资源控制

- 索引队列使用低 QoS。
- 前台搜索优先级高于后台写入。
- 电池供电时降低扫描并发度。
- 设定单次批处理上限和可取消任务。
- 数据库写入使用 WAL 模式。

## 10. 搜索与排序

### 搜索流程

```text
输入文本
  → 解析操作符
  → 生成 SQL/FTS 查询
  → 获取有限候选集
  → 应用层相关性评分
  → 分页返回
```

### 排序建议

初始评分可由以下因素组成：

- 完整文件名精确匹配：最高
- 文件名开头匹配
- 路径匹配
- 词边界匹配
- 最近访问或修改时间
- 当前所在卷/目录偏好
- 文件类型偏好

不要在 MVP 中偷偷收集用户行为。可提供「本机保存最近搜索」开关，默认只保存在本机并允许清除。

## 11. macOS 权限与隐私

### 权限策略

- 首次运行只请求必要的文件访问权限。
- 允许用户选择目录，而不是一开始请求整个磁盘。
- 若用户启用「全磁盘访问权限」，显示原因、范围和设置入口。
- 访问受保护目录失败时记录为不可索引状态，向用户解释原因，不反复弹窗。
- 外接卷按卷单独启用。

### 隐私原则

- 默认离线运行。
- 不上传路径、文件名、查询词或索引数据库。
- 索引数据库存放在 App Support 目录，并支持一键删除。
- 日志默认不包含完整路径；诊断模式需用户主动开启。
- 自动更新、崩溃报告和遥测均提供独立开关。

## 12. MVP 功能清单

### 必须有

- 菜单栏/快捷键打开搜索窗口
- 选择索引目录
- 首次扫描与进度展示
- FSEvents 增量更新
- 文件名、路径、文件夹搜索
- 扩展名、大小、修改时间筛选
- 键盘导航、打开、Reveal in Finder、复制路径
- 暂停/重建/删除索引
- 权限失败和磁盘不可用状态

### 可以后置

- 文件内容搜索
- OCR
- Finder 快速操作扩展
- 自然语言查询
- 自定义快捷指令
- 多设备同步配置
- 插件系统

## 13. 关键交互细节

### 快捷键

- `⌥Space`：打开/隐藏
- `Esc`：清空或关闭
- `↑ / ↓`：移动选择
- `Return`：打开
- `⌘Return`：Reveal in Finder
- `⌘⇧C`：复制路径
- `⌘I`：显示信息
- `⌘P`：预览
- `⌘,`：设置

### 状态反馈

搜索框下方应明确区分：

- `正在索引：已完成 120,340 项`
- `索引已暂停：磁盘不可用`
- `仅搜索已授权目录`
- `结果可能不完整：需要重新扫描`

不能把「暂无结果」误显示成「系统中没有此文件」，因为可能存在权限、尚未索引或卷未挂载等原因。

## 14. 测试方案

### 正确性

- 新建、重命名、移动、删除文件后的索引一致性
- 大小写、重音符号、中文、日文和 emoji
- 路径包含空格、特殊字符和超长路径
- 多个同名文件与重复目录
- 外接盘挂载/卸载
- FSEvents 丢失后的恢复扫描

### 性能

建立包含 10 万、50 万、100 万文件的测试数据集，测量：

- 首次索引耗时
- 输入到首批结果的 P50/P95 延迟
- 增量更新延迟
- 内存峰值
- 空闲 CPU、电池消耗
- 数据库大小

### 安全与权限

- 未授权目录不应被索引
- 删除权限后应用应优雅降级
- 索引数据库不应通过日志泄露完整路径
- 数据库迁移失败时保留旧库并可恢复

## 15. 开发阶段计划

### Phase 0：技术验证（3～5 天）

- SwiftUI 搜索窗口原型
- SQLite + FTS5 查询原型
- 10 万文件扫描性能测试
- FSEvents 最小可用监听

### Phase 1：MVP（2～4 周）

- 索引目录设置
- 首次扫描、增量索引
- 文件名和路径查询
- 基础筛选与快捷键
- Finder 操作
- 权限与索引状态页面

### Phase 2：可用性增强（2～3 周）

- 更好的模糊匹配和排序
- Quick Look 预览
- 外接盘管理
- 导入/导出设置
- 自动更新和签名发布

### Phase 3：高级能力（按优先级）

- 文件内容搜索
- Spotlight/MDQuery 补充
- OCR 与 PDF 文本索引
- Finder 扩展
- 自然语言过滤器

## 16. 推荐项目结构

```text
SwiftFind/
├── App/
│   ├── SwiftFindApp.swift
│   ├── AppState.swift
│   └── Commands.swift
├── Features/
│   ├── Search/
│   ├── Results/
│   ├── Settings/
│   └── IndexStatus/
├── Indexing/
│   ├── InitialScanner.swift
│   ├── FSEventsWatcher.swift
│   ├── IndexCoordinator.swift
│   └── MetadataReader.swift
├── SearchEngine/
│   ├── QueryParser.swift
│   ├── QueryPlanner.swift
│   └── Ranker.swift
├── Persistence/
│   ├── Database.swift
│   ├── Migrations.swift
│   └── FileRepository.swift
└── Shared/
    ├── Models.swift
    └── Diagnostics.swift
```

## 17. 最重要的产品决策

1. **先做文件名/路径搜索，不要一开始做全文搜索。** 这是实现 Everything 体验的核心，也是性能和权限风险最低的路径。
2. **搜索引擎与索引器解耦。** 搜索必须在后台索引时仍然可用。
3. **明确表达索引范围和完整性。** 用户更在意「结果是否可信」，而不只是速度。
4. **默认保护隐私。** 本地索引是产品卖点，不应依赖遥测证明价值。
5. **先验证 100 万文件的实际表现，再决定是否需要更复杂的倒排索引或独立服务。**

## 18. 首个可验收版本

当以下条件全部满足时，可认为 MVP 达标：

- 用户可选择一个或多个目录并完成首次索引。
- 输入文件名关键词后，常见查询在 100 ms 左右返回首批结果。
- 新建、重命名、移动、删除文件能在数秒内反映。
- 结果可用 Return 打开，或用 ⌘Return 在 Finder 中定位。
- 应用重启后索引可复用，不需要每次全量扫描。
- 授权不足、索引暂停、卷卸载等情况有明确状态，不伪装成“没有结果”。
- 在 100 万文件数据集上，空闲状态 CPU 和内存处于可接受范围，并且后台索引可暂停。
