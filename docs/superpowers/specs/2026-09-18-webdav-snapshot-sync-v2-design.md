# WebDAV JSON 快照同步 v2 设计

## 状态

- 设计日期：2026-09-18。
- 设计状态：已确认方向，待实现。
- 目标：将现有「每个实体一个远端事件文件」改为「每台设备一个完整 JSON 快照流」，显著减少 WebDAV 请求数量，同时保留实体级合并、删除 tombstone、冲突版本和原子落库能力。
- v1 事件协议保留为迁移输入，不再作为 v2 的日常写入格式。

## 问题与目标

当前 v1 首次同步会把每个账目、账户、分类等实体写成独立 `.vfsync` 文件。每个文件上传前还会逐级执行 `MKCOL`、执行 `GET` 查重，再执行 `PUT`。数据量达到数千条时，一次同步会放大为数万次 WebDAV 请求。部分服务器会在这一过程中限流、断开连接或让请求超时，表现为普通整包备份上传成功，而自动同步在 `MKCOL ensure_tree` 阶段失败。

v2 必须满足：

1. 无新增附件的正常同步固定为一次根目录 `PROPFIND`、每个有更新的远端设备一次快照 `GET`、本机有待发布变化时一次快照 `PUT`；新增附件只追加缺失 blob 分块的 GET/PUT。最新快照损坏时允许在保留窗口内有限回退 GET，远端清理可以追加少量 `DELETE`，但不阻塞同步成功。
2. WebDAV 只传完整 JSON 快照，不再为单个账目或单个批次创建目录和文件。
3. 本地仍按稳定实体 ID、因果版本和 tombstone 合并，不能退化为整库覆盖或「最后上传者获胜」。
4. 两台设备离线修改不同实体时自动合并；并发修改同一实体、删除与编辑并发时保留冲突版本，由用户决议。
5. 失败不得清空本地待上传状态或推进远端游标；重试必须幂等且不丢数据。
6. 继续使用用户现有 WebDAV 地址、账号、密码和备份加密口令，不增加自有服务端或账号体系。

## 非目标

- 不承诺应用被系统杀死后仍后台实时同步。
- 不把服务器返回的 `Last-Modified` 或设备墙上时钟作为一致性依据。
- 不让多个设备覆盖同一个固定文件名。
- 不在本阶段实现设备撤销、成员权限、服务端锁、在线密钥轮换或跨账号共享。
- 不删除普通手动备份和自动备份，也不改变手动恢复的整库覆盖语义。

## 核心模型

### 每台设备独立快照流

每台设备只写自己命名空间下的不可变快照文件。所有文件直接放在用户配置的 WebDAV 集合根目录，不创建子目录：

```text
verifin-sync-v2-<deviceId>-<20位快照序号>-<UTC时间戳>-<完整SHA256>.json
verifin-sync-v2-blob-<完整SHA256>.blob
```

示例：

```text
verifin-sync-v2-4f8c19e6d7134be39c25820b2f55a912-00000000000000000042-20260918T031522417Z-8b1d09e9e41fa73c53eb3e9570b8f37d4789c478dd09f0bf3cb24e38ae8f0a9.json
```

- `deviceId` 使用现有随机设备身份，生产值严格为 32 位小写十六进制；其他长度或字符直接忽略并记录协议诊断。
- 快照序号是设备内独立、持久化、严格递增的传输序号。它与实体事件 sequence 分离，不能用时间戳替代。
- UTC 时间戳用于列表可读性、日志和候选排序兜底，不参与因果判断。
- 快照和 blob 文件名使用最终上传字节的完整 64 位小写 SHA-256。下载后必须先校验文件名字节 hash，再解密或解析，防止截断、碰撞或服务器内容损坏。
- 文件名解析采用严格正则；普通备份、v1 目录和其他文件全部忽略。
- 普通 WebDAV 备份列表必须排除 `verifin-sync-v2-` 前缀，避免用户把同步快照当作手动备份恢复。

每台设备只删除自己名下的旧快照，并在最新快照上传成功后保留最近 3 份。清理失败只记日志，不把已经成功的同步改判为失败。任何设备都不得删除其他设备的快照。

### 为什么不是单个全局最新文件

若所有设备共同覆盖 `latest.json`，两个离线设备基于同一旧版本上传时，后一次 PUT 会静默覆盖前一次，时间戳再精确也无法恢复被覆盖的数据。每设备独立文件让并发写入变成并列输入，本地 merge 可以同时看到两边，语义相当于多个 Git remote ref，而不是竞争一个工作区文件。

## JSON 快照格式

快照是一个完整、可独立合并的状态文档。它不等同于普通备份恢复文件，但数据白名单继续以 `exportDataForSync()` / `SyncProjection` 为唯一来源。

明文逻辑结构：

```json
{
  "protocolVersion": 2,
  "deviceId": "4f8c...a912",
  "snapshotSequence": 42,
  "createdAtUtc": "2026-09-18T03:15:22.417Z",
  "keyFingerprint": "...",
  "knownVector": {"4f8c...a912": 318, "7a21...bc09": 104},
  "heads": [
    {
      "operationId": "...",
      "entity": {"scope": "ledger", "type": "entries", "id": "..."},
      "version": {"dot": {}, "context": {}, "logicalTime": 0},
      "deleted": false,
      "payloadHash": "...",
      "payload": {}
    }
  ],
  "attachmentBlobs": [
    {"attachmentId": "...", "byteLength": 123, "dataUrlPrefix": "data:image/jpeg;base64,", "chunks": ["完整SHA256"]}
  ],
  "conflicts": []
}
```

约束：

- `heads` 包含本机已知的每个实体当前头版本，包括删除 tombstone。它本身就是完整同步状态，不依赖更早快照。
- 未决冲突的两侧完整版本进入 `conflicts`，确保冲突可以跨设备传播和继续决议。
- 每个非删除实体都必须带完整 payload，且重新计算的 payload hash 必须一致。
- 同一实体在 `heads` 中只能出现一次；同一 operationId 不得对应两个 hash。
- `deviceId`、`snapshotSequence` 必须与文件名一致；`knownVector` 必须覆盖文档内所有版本的 dot/context。
- 文档按稳定键序与实体键排序编码，便于得到确定 hash 和编写黄金测试。
- 配置备份口令时，完整逻辑文档继续使用现有 `SyncCodec` 加密为 JSON 信封；未配置口令时为明文 JSON。两种格式都必须带协议版本和不可逆 key fingerprint，禁止密钥不匹配时回退明文。
- 结构化快照明文上限固定为 16 MiB，最终加密 JSON 信封上限固定为 24 MiB。编码前根据稳定 JSON 编码累计字节并在超过上限时停止；下载按流累计，超过上限立即断开，分别返回 `snapshot_plaintext_too_large` / `snapshot_envelope_too_large`，不得把半份数据交给 `jsonDecode`。该边界不包含独立 blob 的字节。
- 附件原始总量继续受现有备份/导入边界约束；单个原始附件不超过 25 MiB。附件按当前 `SyncWireLimits.chunkBytes` 切块，每块加密后仍须小于 32 MiB，文件名取最终上传密文字节 hash。快照只保存附件 ID、原始长度、data URL 前缀和按顺序排列的块 hash。
- 下载附件时逐块校验文件 hash、解密、校验原始块 hash并写入临时文件；全部块齐全且累计长度正确后才重建 data URL。临时文件无论成功或失败都必须删除，不能同时在内存保留原始字节、Base64 字符串、密文和完整 JSON 四份副本。

v2 的「完整 JSON」指全部结构化业务数据和版本元数据集中在一个快照；图片二进制继续采用内容寻址 blob，以避免 Base64 与 AES-GCM 在 Android 内存中反复复制。附件 head 在进入 wire 快照前必须复用 `syncEventForWire` 去掉 `dataUrl` 并写入 blob chunk 引用，接收端复用 `materializeSyncEvent` 还原并校验原始 payload hash。`sync_snapshot_members.payload_hash` 始终保存 outbox 的原始 materialized hash，而不是 wire payload hash。附件只随新增内容产生少量分块文件，不再为每个账目、账户、分类或批次创建远端碎片。首版不清理远端 blob；没有全设备确认机制前，误删 blob 的数据风险高于节省空间的收益。

## 本地状态

新增快照协议状态，放在 SQLite 同步元数据中：

### `sync_snapshot_state`

单行保存：

- `next_snapshot_sequence`：下一个待保留的本机快照序号；序号在开始编码/上传前持久化保留，崩溃允许留 gap，但绝不复用。
- `last_published_sequence`、`last_published_hash`、`last_published_at`：最近成功发布的本机快照。
- `v1_import_completed`：是否完成一次 v1 只读迁移。

### `sync_snapshot_cursors`

每个远端设备一行：

- `device_id`。
- `last_merged_sequence`。
- `last_merged_hash`。
- `last_merged_at`。

游标只在快照完整下载、hash/协议/密钥/引用校验通过，并且合并结果与冲突记录成功落库后推进。服务器文件时间不写入游标。

### `sync_snapshot_publications` 与 `sync_snapshot_members`

发布准备必须在一个 SQLite 事务中完成：

- 保留新的 `snapshot_sequence`，写入 `sync_snapshot_publications` 的 `prepared` 状态。
- 在同一事务读取当前全部 heads、未决冲突和 `uploaded = 0` 的 outbox，形成不可变的 `PreparedSyncSnapshot` 内存值。
- 对每条待上传 operation，只有它直接出现在 heads/冲突版本中，或被快照中同实体的后继版本因果覆盖时，才写入 `sync_snapshot_members(snapshot_sequence, operation_id, payload_hash)`。无法证明覆盖的 operation 必须作为额外版本写进快照，不能被遗漏。
- `sync_snapshot_members` 以 `(snapshot_sequence, operation_id)` 为主键；同一 operationId 的 hash 与 outbox 不一致时立即中止准备。

PUT 成功后，`markSnapshotPublished(snapshotSequence, filename, hash)` 在单个事务内：

1. 校验 publication 仍为 `prepared` 且文件名/hash 一致；
2. 只把 `sync_snapshot_members` 明确列出的 operationId 标记为 uploaded；
3. 更新 last published；
4. 把 publication 改为 `published`。

现有按 `batchId` 整批确认的 `markBatchUploaded` 不用于 v2。实现新增按 operationId 精确确认的仓储接口；即使一个旧批次中的部分 operation 在快照准备后又发生变化，也不能误清另一部分。准备事务提交后产生的新 outbox 不属于该快照，必然留待下一轮。

编码、加密或上传失败时 publication 保持/转为 `abandoned`，members 不触碰 outbox。若远端 PUT 成功但应用在本地发布事务前崩溃，下次启动不猜测远端结果：废弃旧 prepared 记录、保留 outbox、用更高序号发布新的完整快照。重复远端内容按 operationId 幂等，序号允许出现 gap。

现有 `sync_shadow`、`sync_entity_versions`、`sync_entity_heads`、`sync_outbox`、`sync_applied_ops`、`sync_pending`、`sync_apply_journal` 和 `sync_conflicts` 继续承担变更捕获、版本保存、原子应用与冲突决议。v2 是传输格式替换，不另造第二套业务合并真相。

为生成完整快照，`SyncRepository` 增加事务化的 `prepareSnapshotPublication` 接口，一次性读取当前全部 entity heads、未决冲突和 outbox 截止线。快照必须从同步元数据的稳定版本行构建，而不是先读 Controller JSON、再异步读取版本表后拼接，避免本地写入夹在两次读取之间造成 payload 与版本不一致。

## 同步流程

所有触发继续由 `SyncCoordinator` 串行化。一次 v2 同步按以下顺序执行：

1. 重放未完成 KV journal，等待本地业务写入完成。
2. 执行 `SyncChangeTracker.reconcile()`，把当前本地变化持久化为实体版本和 outbox。远端应用期间仍抑制回声。
3. 对 WebDAV 根目录执行一次 `PROPFIND Depth:1`，解析所有合法 v2 文件；不执行 `MKCOL`。
4. 按设备分组。对每个远端设备选择序号高于本地游标的最新候选；同一 deviceId + sequence 出现多个文件时，先比较文件名完整 hash，hash 不同立即报 `snapshot_sequence_collision`，相同才去重。
5. 只下载选中的候选。若最新文件损坏，可按序号倒序尝试仍高于游标的保留版本；没有有效候选时失败且不推进游标。成功后游标只能写入**实际通过校验并完成合并**的 fallback 序号和完整 hash，不能写最初选中的损坏序号；更高的损坏文件下一轮仍会重试。
6. 校验并解密快照，将 heads 和冲突版本转成现有实体版本模型；按根目录列表检查引用的 blob，下载本机缺少的块并完成附件 hash/长度校验。缺块时本快照保持 pending，不提交半份业务状态。
7. 逐快照规划实体级 merge：因果后继覆盖前序；真正并发写入冲突表；删除保持 tombstone。所有可接受实体共同折叠后通过 `SyncLedgerReducer` 做完整引用和金额校验。
8. 在现有远端应用事务中一次写入业务表、实体版本、完整 shadow、applied 信息、冲突和 KV journal。无冲突实体可以正常应用；冲突实体保持当前本地值并保存两侧版本，不得因为一条冲突阻止同一快照内其他独立实体合并。该事务同时写入实际成功候选的 cursor sequence/hash。
9. 成功提交后推进该远端设备游标。任一阶段失败都保留原游标，下次重试同一快照。
10. 如果本机 outbox 非空、尚未发布过 v2 基线，或本轮生成了本机冲突决议事件，则调用事务化 `prepareSnapshotPublication` 固化 heads、冲突、outbox 成员和新快照序号。先上传根目录列表中尚不存在的附件 blob，再执行一次快照 PUT；blob 上传成功而快照失败是安全的未引用冗余，下轮按 hash 复用。
11. PUT 成功后通过 `markSnapshotPublished` 按 `sync_snapshot_members` 的 operationId 精确确认 outbox 并记录发布状态；上传准备事务之后产生的新 outbox 不在成员表中，保留到下一轮。
12. best-effort 删除本机第 4 份及更旧快照，更新同步状态和结构化日志。

这相当于 pull-before-push。无远端新序号且本地 outbox 为空时，一轮同步只有一次 `PROPFIND`，不执行 GET 或 PUT。

## 合并与冲突

- 稳定实体键、dotted version vector、删除 tombstone 和 operationId 继续沿用 v1 当前模型。
- 本地新增 A 与远端新增 B 取并集。
- 同一实体的因果后继替代前序。
- 同一实体互不包含的版本形成冲突；当前本地 materialized 值保持不变，冲突两侧均持久化。
- 删除和编辑并发形成冲突，不能靠完整快照中「缺少实体」推断删除。
- 用户决议产生新的本机实体版本和 outbox。下一份本机完整快照传播决议，其他设备按因果后继收敛。
- 已处理 operationId + 相同 hash 幂等忽略；相同 operationId + 不同 hash 立即拒绝。
- 远端快照包含完整状态，但不执行整库覆盖。合并仍调用 Controller 的 typed reducer 和 SQLite 事务边界。

### 冲突的跨设备身份与决议

冲突不能使用观察方向相关的 `local/remote` ID。v2 对每一对并发最大版本计算 canonical key：

```text
sha256(encodeSyncEntityKey(entity) + "\n" + min(operationA, operationB) + "\n" + max(operationA, operationB))
```

- 接收端不信任快照携带的 conflict ID，必须从实体键和两侧 operationId 重算。
- `operationA/B` 按字典序排序后存储，展示时再映射为「本机版本/其他设备版本」，保证两台设备对同一冲突得到相同 ID。
- 三个及以上并发最大版本按两两 canonical pair 保存；数据库唯一键去重，UI 按实体聚合为一个待决议项，展示全部候选版本。
- 用户对某实体作出决议时，新 resolve 事件的 context 必须合并该实体全部未决最大版本的完整 vector，而不是只合并当前打开的两侧。
- 应用 resolve 事件后，删除该实体所有被 resolve 完整 vector 因果覆盖的 conflict pair；仍有不被覆盖的新并发版本时保留对应 pair。
- 快照导出所有未决最大版本；其他设备收到 resolve 后按同一规则清理，不能依赖来源设备的本地 conflict ID。

## 触发与时间语义

- 冷启动、回到前台、本地修改后去抖、用户点击「立即同步」均执行上述流程。
- 文件名 UTC 时间戳让根目录列表可快速判断候选的新旧，也用于日志展示。
- 真正的「是否需要下载」条件是 `snapshotSequence > lastMergedSequence`。不能只比较远端时间戳与本地最后同步时间，因为设备时钟可能漂移或回拨。
- 设置页现有「最近成功时间」继续表示本机一次完整同步成功的本地时间，不作为远端协议游标。
- 多次点击手动同步仍由 `SyncCoordinator` 串行；运行中的重复点击至多排队一次，不并发访问 WebDAV。

## WebDAV 传输

新增快照 transport，只操作配置集合根目录：

- `listSnapshots`：一次 `PROPFIND Depth:1`，使用结构化 XML 解析和严格同源/根路径校验。
- `downloadSnapshot`：GET，沿用 v1 已修复的安全重定向规则；同源跳转可带认证，跨源跳转不得携带认证，禁止 HTTPS 降级、循环和超过上限。
- `uploadSnapshot`：对唯一文件名执行一次 PUT，不预先 MKCOL、不逐文件 GET。接受 200/201/204；HTTP 失败保留 outbox。
- `deleteSnapshot`：只清理经过严格解析且 deviceId 等于本机的旧 v2 文件。
- 每个操作继续输出不含 URL、路径、账号、Authorization、账目正文的结构化诊断。

用户配置的 WebDAV 集合本身若不存在，普通上传和连接测试也无法稳定工作；v2 不再自行创建深层目录。这样与已经验证可用的「上传到 WebDAV」使用同一个能力边界。

同步 transport 与普通备份客户端必须共用一个安全 href 解析器：

- 只接受 `http` / `https`，解析后的 scheme、host、port 必须与配置集合一致。
- 解析后的规范化 path 必须位于配置集合 path 前缀内，拒绝 `..`、编码斜杠、query、fragment、authority-relative URL 和跨源绝对 URL。
- 普通备份的 list 结果在进入恢复 UI 前排除 `verifin-sync-v2-` 快照和 blob；download/delete 再次执行同源与根路径校验，不能把服务器返回的 href 直接带 Basic Auth 请求。
- 快照列表只接受严格文件名；日志只记录 `file=snapshot/blob/backup` 等类别，不记录 href。

## v1 迁移与混合版本

升级后的首次 v2 同步执行一次迁移：

1. 读取并应用远端已完整提交的 v1 批次，不再上传任何 v1 文件。
2. v1 中缺 manifest/commit/blob 的半批不视为权威数据；记录迁移日志，但不覆盖本地状态。
3. 当前本地未版本化的数据生成基线实体版本；现有 v1 outbox 的完整事件直接并入本机 heads。
4. 完成远端 v1 合并后发布本机首个 v2 完整快照。
5. 只有首个 v2 快照 PUT 成功后，才标记 `v1_import_completed` 并把已包含的旧 outbox 标为已上传。
6. 后续日常同步只扫描根目录 v2 文件，不再递归扫描 v1 树。

v1 客户端无法读取 v2 快照。升级发布说明和设置页需要明确：参与同一 WebDAV 同步的设备应全部升级到支持 v2 的版本；仍停留在 v1 的设备写入不会被 v2 设备持续监听。为避免隐藏的双向不兼容，首次发现 v1 历史但没有其他 v2 设备快照时，在同步状态中记录迁移提示。

普通 `verifin-auto-*` / `verifin-backup-*` 文件完全不参与同步 merge。旧 `verifin-sync/v1/` 目录不自动删除，作为迁移恢复依据保留。

## 错误、日志与恢复

每次同步继续使用短 run ID，并记录：

- `prepare`、`reconcile`、`discover`、`download`、`merge`、`upload`、`cleanup` 阶段起止。
- 发现的设备数、候选快照数、实际 GET/PUT/DELETE 数、下载/合并实体数、冲突数、剩余 outbox 数。
- WebDAV method、operation、file kind、HTTP status、redirect count/relation、稳定 reason。
- 快照协议错误码：文件名非法、hash 不符、密钥不符、协议版本不支持、内容超限、实体重复、operation 碰撞、引用校验失败。

日志禁止包含完整 URL、远端文件名中的 deviceId 全值、用户凭证、密文、payload 或账目内容。deviceId 只显示短指纹。

失败恢复规则：

- 列表/下载/合并失败：不推进对应游标，不上传基于不完整远端状态的快照。
- 上传失败：不标记 outbox uploaded，不更新 last published。
- 上传成功但本地提交状态前崩溃：下次把旧 prepared publication 标为 abandoned，保留全部 outbox，并用更高序号发布完整快照；旧成功文件与新文件内容可重复，但 merge 按 operationId 幂等。
- 清理失败：同步仍成功，后续重试清理。
- JSON 或远端响应超过上限：立即停止读取并返回稳定错误，不把半份数据交给 `jsonDecode`。

## 测试与验收

### 协议与纯函数

- 文件名编码/解析、UTC 时间戳、20 位序号、严格前缀和 hash 校验。
- 快照稳定编码、明文/加密 round-trip、密钥不匹配、重复实体、重复 operationId、tombstone 和冲突版本。
- 每设备候选选择只取高于游标的最新有效序号，不受服务器 `Last-Modified` 或设备时钟回拨影响。

### Repository 与迁移

- schema version 提升；从每个历史版本升级到当前版本。
- 快照序号保留不复用；逐设备游标只在成功 merge 后推进。
- 快照从一次 SQLite 一致性读取获得完整 heads/冲突。
- 上传成功按 `sync_snapshot_members.operation_id` 只清理实际包含或被证明因果覆盖的 outbox，上传期间新增变更继续待传。
- 本机 A 入队后被后继 B 覆盖时，快照成员同时记录 A/B，发布后两者都精确确认；同批次存在未包含 operation 时不得按 batch 清空。
- canonical conflict key 在两台设备方向相反时相同；三个并发版本按实体聚合，决议事件覆盖并清除所有已决 conflict pair。

### 真实本地 HTTP WebDAV

- 首次含至少 1000 个实体的同步只能出现一次根目录 PROPFIND 和一次快照 PUT，不允许任何 MKCOL、逐实体 GET 或逐实体 PUT。
- 普通备份上传成功而重复 MKCOL 会断连的服务器模型下，v2 同步仍成功。
- GET 302 同源/跨源认证规则、PUT 状态码、截断响应、hash 损坏、超限、DELETE 清理失败。
- 根目录同时存在普通备份、v1 目录、未知文件和多设备 v2 快照时只选择合法候选。
- 普通备份列表不展示 v2 JSON/blob；恶意跨源、越出集合、带 query/fragment 的 PROPFIND href 无法进入普通备份 download/delete，且不会携带 Basic Auth。
- 最新快照损坏而上一份有效时，cursor 只推进到实际合并的 fallback sequence/hash；修复或替换更高序号文件后仍会再次尝试。

### 双设备与生产边界

- 两个真实 SQLite/controller 离线新增后收敛。
- 因果编辑自动替换；并发编辑、删除/编辑形成可决议冲突。
- 无远端更新且无 outbox 时第二轮只 PROPFIND，不 GET/PUT。
- 冷启动、回前台、本地修改去抖和手动同步均走同一运行时。
- v1 完整批次迁移一次，半批不应用，首个 v2 PUT 失败时迁移状态不推进。
- v2 快照 PUT 成功后、`markSnapshotPublished` 前模拟崩溃：重启后不得清空旧 outbox，发布更高序号后最终收敛且远端重复 operation 不产生重复业务行。
- 软件日志可以直接复制定位，并确认不含地址、路径、凭证和 payload。
- 结构化 JSON 接近 16 MiB、加密信封接近 24 MiB、单附件接近 25 MiB 及多附件场景均不 OOM；超限返回稳定错误、游标/outbox 不推进、临时文件被删除。

完成实现后必须运行 `dart format .`、`flutter analyze` 和全量 `flutter test`。Android APK/AAB 只通过 GitHub CI 构建；真实 WebDAV 与两台 Android 设备的覆盖安装、冷启动、前后台切换和冲突决议仍作为发布前真机验收。

## 交付边界

- 同步 v2 上线后不再通过 v1 碎片文件执行日常上传或扫描。
- 不保留「v1 写入失败则悄悄改用普通备份覆盖」的降级路径。
- 不要求用户清除应用数据；升级必须迁移已有 SQLite 同步元数据。
- `docs/dev/tech-decisions.md`、`docs/dev/known-limitations.md`、`docs/acceptance-checklist.md`、README 和 CHANGELOG 随实现同步更新。
