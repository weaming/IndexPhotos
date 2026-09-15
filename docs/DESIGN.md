# IndexPhotos 最终设计

设计版本：1.0  
目标平台：macOS 15+  
应用形态：SwiftUI 原生 macOS 应用  
缓存根目录：`~/.index-photos/`

本文是后续实现的稳定基线。除非发现安全性、数据一致性或性能模型上的问题，否则不修改总体设计；具体实现细节可在代码和测试中调整。

## 1. 目标与边界

IndexPhotos 用于在一个或多个用户指定目录中查找：

- 字节完全相同的照片；
- 重新压缩、改格式、缩放、亮度变化产生的近重复照片；
- 裁剪、旋转、镜像、边框、局部遮挡后的近重复照片。

照片的拍摄时间和目录位置只作为展示和删除建议依据，不作为候选过滤条件。

应用只索引原始文件，不复制或修改原始照片。删除操作默认移动到 macOS 废纸篓，并要求用户在结果页确认。

“重复”和“相似”是两种不同的输出：只有字节完全相同的文件进入重复组；经过去污、磨皮、曝光调整、裁剪等处理的同源照片进入相似候选，供后续人工查看和处理，不自动归入可删除重复组。

## 2. 总体架构

```text
SwiftUI
  │
  ├─ ScanCoordinator actor       扫描会话、暂停、恢复、取消
  ├─ CacheStore actors            SQLite、缩略图、检查点、缓存回收
  ├─ PhotoSource                  目录枚举、权限书签、文件状态
  ├─ DecodeProvider               ImageIO/Quick Look/可选 RawKit
  └─ FeatureProvider              pHash、Vision/SSCD embedding、几何复核
          │
          └─ Rust Core FFI         BLAKE3、pHash、向量距离、HNSW、分组
```

Swift 负责文件系统权限、目录枚举、ImageIO、Core ML/Vision、SQLite、缓存生命周期和 UI。Rust 仅负责稳定、可基准测试的算法核心，通过窄的 C ABI 暴露给 Swift；不引入 Go，避免同时维护两套 FFI 和运行时。

SwiftUI 使用 `@Observable` 的小粒度状态对象和 actor 隔离的服务。扫描进度以节流后的快照发布给 UI，视图不直接读取数据库或执行图像解码。

## 3. 缓存目录

所有应用生成的数据都放在 `~/.index-photos/`：

```text
~/.index-photos/
├── manifest.json
├── catalog.sqlite
├── catalog.sqlite-wal
├── catalog.sqlite-shm
├── vectors/
│   ├── generations/
│   │   └── <generation-id>/
│   │       ├── hnsw.bin
│   │       ├── meta.json
│   │       └── READY
│   └── CURRENT
├── thumbnails/
│   ├── small/<object-key>.jpg
│   └── medium/<object-key>.jpg
├── work/
│   └── scans/<scan-id>/
├── logs/
└── locks/
    └── index.lock
```

约束：

- `catalog.sqlite` 是照片状态、特征和重复组的唯一事实源。
- `manifest.json` 保存缓存格式版本、当前模型、向量维度、距离度量和生成器版本。
- 缩略图、HNSW 和工作目录都是可重建数据；丢失后不能导致原图丢失。
- 所有临时文件先写入 `work/`，完成后在同一文件系统内原子替换。
- 不在缓存中保存原始照片，只保存路径、文件标识和 security-scoped bookmark。
- 应用启动时确保目录存在，并检查 SQLite、`CURRENT` 和未完成扫描。

缓存根目录由 `FileManager.homeDirectoryForCurrentUser` 拼接 `.index-photos` 得到，不硬编码用户名称。

## 4. 缓存数据模型

SQLite 初始建表只使用 `CREATE TABLE IF NOT EXISTS` 等初始化语句，不使用运行时 `ALTER` 迁移。后续结构变化通过新的 schema 初始化版本或重建缓存处理。

核心表：

| 表 | 作用 |
| --- | --- |
| `cache_meta` | schema、应用版本、算法版本、最后清理时间 |
| `roots` | 扫描目录、显示名称、卷标识、bookmark 数据 |
| `scan_sessions` | 扫描会话、阶段、状态、计数和配置快照 |
| `scan_items` | 当前会话逐文件任务和断点状态 |
| `assets` | 照片稳定身份、当前路径、大小、mtime、BLAKE3 |
| `asset_features` | pHash/dHash、embedding、缩略图对象和版本 |
| `duplicate_groups` | 仅保存完全重复文件的重复组 |
| `duplicate_members` | 重复组与照片的关系 |
| `similarity_candidates` | 轻微修改、裁剪、曝光变化等相似关系及证据 |
| `review_decisions` | 用户对相似候选的保留、忽略或后续处理状态 |
| `cache_objects` | 缩略图等派生文件的大小、引用数和 LRU 时间 |

文件身份优先使用卷标识与文件资源标识；不可用时使用规范化路径。内容指纹使用：

```text
source_fingerprint = volume_id + file_id/path + size + mtime_ns
content_hash       = BLAKE3(file bytes)
```

路径变化但内容未变时复用特征。大小或 mtime 变化时重新验证；BLAKE3 相同只能作为候选判定，涉及删除前再做字节级比较。

每种派生特征都带有独立版本：

```text
feature_key = asset_id + source_fingerprint + feature_kind + algorithm_version
```

模型 embedding 还记录模型名称、模型文件 SHA-256、输入预处理、向量维度、是否归一化和距离度量，防止不同模型的向量误混入同一个 HNSW。

## 5. 扫描阶段

扫描分为可独立提交的阶段：

1. `prepare`：取得目录权限、加载缓存、恢复异常会话。
2. `enumerate`：递归枚举图片文件，只读取 URL 资源属性，不读取完整文件内容。
3. `fast_features`：按大小分组，计算 BLAKE3、鲁棒缩略图哈希、尺寸和 EXIF。
4. `embedding`：对需要高召回的照片计算一次 image-copy embedding；快速模式只处理疑难候选。
5. `index`：从已持久化的 embedding 建立或更新 HNSW。
6. `verify`：只对 pHash/HNSW 找出的少量候选执行 ORB/SIFT + RANSAC，并区分重复关系和相似关系。
7. `finalize`：生成精确重复组和相似候选，标记消失文件、清理临时任务和过期缓存。

对小型常规照片，使用一次顺序流式读取：文件数据同时送入增量 BLAKE3 和 ImageIO 顺序数据提供器；ImageIO 尽早降采样到受限尺寸，再由同一缩略图生成 pHash。解码器未消费到文件尾时，扫描器只补读尚未哈希的尾部，不重新读取已处理内容。大 RAW/TIFF 根据内存预算走分阶段路径；已完成的特征不会因为后续阶段中断而失效。

## 6. 断点续扫设计

### 6.1 核心原则

目录枚举器的当前位置只作为性能提示，不能作为唯一断点。恢复时重新枚举目录，并依据 `asset_id + source_fingerprint + feature_version` 跳过已提交且仍有效的任务。

因此以下情况都可以安全恢复：

- 应用崩溃或被强制退出；
- Mac 睡眠、硬盘暂时断开或权限暂时失效；
- 照片在扫描期间新增、删除或移动；
- 扫描中途切换暂停、取消或升级应用。

### 6.2 会话状态

`scan_sessions.status` 使用以下状态：

```text
queued → running → pausing → paused
                    ├──────→ completed
                    ├──────→ cancelled
                    └──────→ failed
```

每个会话保存：

- `scan_id`、目标 root、创建和更新时间；
- 当前阶段和阶段版本；
- 配置快照，例如快速/高召回模式、模型版本和阈值；
- discovered、committed、failed、missing、total_bytes 等计数；
- `last_checkpoint_at`、heartbeat 和最近错误；
- 仅用于加速恢复的 `last_path_hint`，不把它当作正确性依据。

### 6.3 逐文件任务状态

`scan_items` 保存每个会话的任务状态：

```text
discovered → pending → processing → staged → committed
                         └──────────────→ retryable_failed
                         └──────────────→ permanent_failed
```

规则：

- `processing` 必须带 heartbeat；恢复时超过超时时间的任务改回 `pending`。
- `staged` 表示结果清单、特征和校验值已写入 `work/scans/<scan-id>/`，可直接完成提交，不必重新读取原图。
- `committed` 只有在派生文件和 SQLite 事务都成功后才设置。
- 单文件错误不阻塞整个扫描；权限、损坏、格式不支持等错误保存错误码和可读信息。
- 暂时性错误采用有限次退避重试，永久错误进入失败列表，允许用户单独重试。

### 6.4 检查点与提交

每处理一小批文件或经过短时间间隔就提交检查点，具体批量大小根据 HDD、内存和基准测试调整。一次提交必须包含：

1. 任务阶段和源文件指纹；
2. 新的 `assets` 与 `asset_features` 记录；
3. 缩略图对象引用和 LRU 信息；
4. 当前阶段计数与 heartbeat。

提交顺序：

```text
写入 work 临时结果、结果清单和校验值
→ SQLite 事务记录 staged 检查点
→ 原子移动缩略图/中间文件到最终位置
→ SQLite 事务写入特征和任务 committed
→ 删除本次 work 临时文件
```

恢复时根据 staged 清单检查最终文件；文件已落盘则直接完成 SQLite 提交，文件未落盘则从 work 结果继续发布。崩溃时最多留下孤儿文件或未完成任务，不会产生“数据库认为完成但特征文件不存在”的正常提交状态。启动恢复会扫描 `work/` 和 `cache_objects`，删除无引用的临时对象。

### 6.5 暂停、取消与恢复

- 暂停：停止继续枚举，取消排队中的任务，等待当前 HDD 读取和 CPU 任务安全结束，提交检查点后进入 `paused`。
- 取消：保留已经 `committed` 的结果，清理未提交任务；下次可对该目录执行增量扫描。
- 恢复：加载原会话配置，重新枚举目标目录，只补做缺失、过期和失败重试的任务。
- 应用启动：将遗留的 `running/pausing` 会话置为 `recovering`，完成一致性检查后在 UI 中提供继续入口。
- 只有基础设施错误、缓存不可写或数据库损坏才将会话置为 `failed`；用户可以从最近检查点重新开始。

## 7. 算法分层

### 7.1 精确重复

先按文件大小分组，再对可能重复的文件顺序计算 BLAKE3。哈希一致后，在执行删除前进行字节级比较，确保不会因哈希碰撞产生误删。

### 7.2 快速视觉筛选

从 ImageIO/Quick Look 取得方向正确的缩略图，在同一次解码结果上生成少量派生视图：灰度、亮度归一化和梯度/边缘图。对这些视图计算 pHash、dHash 或等价的鲁棒哈希，形成候选信号。

这些哈希只用于快速召回，不能单独确认重复。亮度归一化和边缘图能减少曝光、色调、磨皮等变化对结果的影响；所有派生视图都在内存中生成，不增加 HDD 读取次数。阈值由包含真实修图样本的基准数据集校准，不按固定拍摄时间或目录位置缩小范围。

### 7.3 向量检索

优先验证 SSCD 或兼容的 image-copy detection 模型。此类模型是“同图变换”检索模型，比通用语义相似度更适合作为近重复照片候选器。模型输入和输出规范写入 manifest；向量归一化后使用 cosine 距离，建立全局 HNSW 近邻索引。

默认每张照片保存一个主 embedding。只有主向量处在候选边界、检测到明显裁剪，或照片属于需要高召回的模式时，才从已经缓存的缩略图在内存中生成亮度归一化、灰度或多裁剪视图，并保存可选辅助向量。辅助向量使用独立的 `embedding_variant` 标识，不能与不同预处理的主向量混为同一指标。

SSCD 官方仓库目前主要提供 TorchScript/权重且已归档，因此必须先完成 Core ML 或其他离线部署方式的转换、精度和许可证验证。若转换不可接受，使用 Vision Feature Print 作为可替换后端，不改变扫描和缓存协议。

HNSW 是派生索引：

- 以 SQLite 中已提交的 embedding 为事实来源；
- 新索引在 `vectors/generations/<id>/` 中构建；
- 写入 `READY` 和校验元数据后，原子替换 `vectors/CURRENT`；
- 构建中断时保留旧索引，恢复时可从 SQLite embedding 重建，不读取原图；
- 删除使用 tombstone，达到阈值后生成新一代索引。

### 7.4 几何复核

只对向量或感知哈希找到的少量候选执行局部特征匹配和 RANSAC 单应性验证。默认优先 SIFT，资源受限或候选较多时使用 ORB 做快速初筛。

复核不仅看匹配点数量，还要同时满足：内点比例、单应性稳定性、匹配点空间分布和源图覆盖率。去污、磨皮或局部涂抹产生的变化会成为少量外点，不应因为这些局部点不匹配而否定整体照片相同。

### 7.5 轻微修改照片

去污、磨皮、局部修容通常保留主体构图、边缘、姿态和大部分未修改区域，但会改变局部像素纹理。专门采用以下复核路径：

```text
主 embedding 找候选
→ SIFT/ORB + RANSAC 对齐
→ 亮度/色彩归一化
→ 网格化低频结构和梯度相似度
→ 忽略局部异常块，计算鲁棒聚合分数
```

对齐后的缩略图分成固定网格，比较低频亮度和梯度结构；不使用全图平均像素误差，而使用中位数、较高分位块分数或带异常值抑制的聚合方式。这样局部皮肤区域被修改时，未修改的眼睛、头发、衣物、背景和构图仍能贡献主要分数。

相似度结果由多种证据共同决定：

| 信号 | 主要作用 | 是否可单独确认 |
| --- | --- | --- |
| BLAKE3 + 字节比较 | 完全相同文件 | 可以确认字节重复 |
| 鲁棒 pHash/dHash | 曝光、压缩、轻微滤镜的快速召回 | 不可以 |
| copy-detection embedding | 裁剪、格式转换、局部编辑的全局召回 | 不可以 |
| SIFT/ORB + RANSAC | 局部修改、旋转、裁剪和遮挡复核 | 需要结合覆盖率 |
| 对齐后的网格结构分数 | 判断大部分构图是否一致 | 需要结合其他信号 |

不把人脸识别 embedding 作为主要判据，避免把“不同照片但人物相同”误认为同一张照片。人像场景的人脸关键点只能作为可选辅助证据。

轻微修改照片一律写入 `similarity_candidates`，关系类型标记为 `edited_same_photo` 或其他具体变换类型，不写入 `duplicate_groups`，也不触发删除建议。用户后续可在相似候选页进行查看、标记、忽略或交给后续处理流程。

精确重复与相似候选分开显示：精确重复可以进入删除确认流程；相似候选只提供证据、置信度和原图引用，默认不执行任何文件操作。相似候选的人工决定写入 `review_decisions`，算法版本更新后保留这些决定供用户复核。

## 8. 机械硬盘与并发

- 每个物理卷默认一个读取队列，最多两个顺序读取 worker。
- 目录枚举、文件读取和 CPU/模型队列分离；内存队列设上限，避免把照片全部缓存到内存。
- 通过 URL 资源属性预取减少无效 stat；按目录顺序读取，尽量避免随机寻道。
- 解码、哈希和特征计算可使用受控 CPU 并发，但不能反向增加 HDD 随机读取。
- 大文件使用分块流式 BLAKE3，并通过顺序 `CGDataProvider` 与 ImageIO 共享同一读取流；缩略图使用 ImageIO 下采样，禁止把原始 20MP/50MP 图片直接交给 UI。
- 使用 os_signpost 或统一日志记录每阶段吞吐、队列等待、解码耗时和失败原因，以基准测试决定并发参数。

## 9. 缓存生命周期管理

### 创建

首次启动创建目录、子目录、manifest、SQLite 和锁。初始化失败必须显示明确路径和原因，不允许静默改写到其他位置。

### 更新

所有更新都经过 CacheStore actor。派生文件采用临时文件加原子替换；SQLite 使用事务和 WAL。文件指纹未变且版本匹配时直接复用缓存；内容或算法版本变化时生成新对象，提交成功后再回收旧对象。

### 删除与回收

- “清理派生缓存”：删除可重建的缩略图、HNSW 和临时文件，保留照片目录、书签、BLAKE3 和 embedding。
- “重建索引”：保留 SQLite 和 embedding，只重建 HNSW，不重新读取原图。
- “删除扫描库”：清除指定 root 的数据库记录、引用缩略图和向量 tombstone，不影响原始照片。
- “清空全部缓存”：用户二次确认后删除 `~/.index-photos/` 内应用数据，原始照片不受影响。
- 缩略图按可配置上限执行 LRU；无引用对象立即可回收，引用对象不得删除。
- `work/` 中超过保留时间且不属于活动会话的文件自动清理。

### 一致性检查

启动和用户手动触发时检查：

- SQLite integrity；
- `CURRENT` 指向的 HNSW generation 是否包含 `READY`、元数据和校验值；
- 数据库引用的缩略图是否存在；
- 是否存在无引用缓存对象；
- 是否有过期锁、孤儿 work 文件和遗留活动会话。

检查失败时优先修复或重建派生缓存，不删除事实数据。

## 10. SwiftUI 界面

主窗口使用 `NavigationSplitView`：

- 左侧：扫描目录、会话状态和缓存状态；
- 中间：扫描进度或重复组；
- 右侧：照片详情、相似度、文件信息和删除建议。

扫描状态只发布不可变的 `ScanProgressSnapshot`，包含阶段、已发现数、已提交数、失败数、总字节、已处理字节、总量是否已知、可暂停/恢复/取消状态和最近错误。目录枚举完成前不伪造精确百分比，可显示已处理数量和字节；进度更新节流，避免每个文件触发整棵视图树刷新。

结果列表和缩略图网格使用稳定的 `asset_id`，采用 lazy 容器，缩略图从缓存异步加载。所有耗时任务都在 actor 或后台任务中执行，不放在 View 的 `body`、初始化器或主线程。

## 11. 权限与安全

若启用 App Sandbox，应用不能默认写任意 Home 目录。要坚持固定的 `~/.index-photos/` 路径，首版采用直签/Developer ID 分发；若以后上 Mac App Store，首次必须由用户授权 Home 目录或其父目录，并保存 security-scoped bookmark。

缓存中的路径和 bookmark 属于敏感本地数据。日志不得写入照片内容、完整 embedding 或不必要的个人路径；日志使用带时区的 ISO 8601 时间。

## 12. 实施顺序与验收

1. 创建 Xcode SwiftUI 工程、缓存根目录、SQLite 初始化和单实例锁。
2. 实现 `scan_sessions`、`scan_items`、检查点、暂停/取消/恢复和崩溃恢复测试。
3. 实现 ImageIO 单遍读取、BLAKE3、缩略图和 pHash。
4. 完成 Rust FFI、embedding provider 和 HNSW generation 原子切换。
5. 加入 ORB/SIFT + RANSAC、重复组展示和安全删除。
6. 使用真实 HDD、断电模拟、权限变化、大 RAW、几十万文件和大缓存进行基准测试。
7. 建立修图鲁棒性测试集，覆盖 JPEG 重压缩、缩放、曝光/白平衡、裁剪、旋转、镜像、边框、水印、去污、磨皮、局部涂抹和滤镜，并分别测量召回率、误报率、几何复核耗时。

第一阶段完成的最低验收条件：扫描中途强制退出后，重新打开应用可以显示上次会话；点击继续后不重新处理已提交文件；缓存或 HNSW 损坏时可重建；同一照片经过亮度调整、去污和磨皮后仍能进入候选；原始照片不会因缓存清理或索引删除而被删除。

## 13. 研究依据

- [Apple Image I/O](https://developer.apple.com/documentation/imageio)
- [Apple macOS Sandbox 文件访问](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [Apple VNFeaturePrintObservation](https://developer.apple.com/documentation/vision/vnfeatureprintobservation)
- [Apple FileManager 目录枚举](https://developer.apple.com/documentation/foundation/filemanager/enumerator(at:includingpropertiesforkeys:options:errorhandler:))
- [SSCD Copy Detection](https://github.com/facebookresearch/sscd-copy-detection)
- [HNSW 论文](https://arxiv.org/abs/1603.09320)
- [Rust FFI](https://doc.rust-lang.org/nomicon/ffi.html)
- [RawKit](https://docs.rs/rawkit/latest/rawkit/)
