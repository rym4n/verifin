# WebDAV 双向同步设计

## 状态

- 目标：在不增加服务端的前提下，让多个设备通过同一 WebDAV 目录协作维护同一组 Veri Fin 数据。
- 设计状态：已确认（2026-09-14）。
- 本设计不改变现有手动备份、自动上传和“从 WebDAV 恢复”的语义；同步是新增协议。

## 目标与非目标

### 目标

1. 继续使用现有 WebDAV 地址、账号和密码。新设备先按现有流程恢复备份，再启用自动同步。
2. 同步范围与当前 `exportDataJson()` 的数据范围一致：所有账本、账目、账户、账户分组、分类、标签、附件、周期规则、汇率、预算、个人资料，以及当前已进入备份的主题、面板、排序、默认账户和金额显示等偏好。
3. 只上传本地尚未同步的变更，并下载本地尚未应用的远端变更，避免重复上传整包快照。
4. 离线期间同时修改时不静默丢数据：冲突版本同时保存，用户选择后生成新的决议变更。
5. 首版保证前台最终一致：应用启动、回到前台、变更后防抖以及手动操作均可触发同步。

### 非目标

- 不增加账号、成员管理、邀请、设备撤销、权限分级或新的同步服务器。
- 不承诺应用完全退出或被系统杀死后仍实时同步；后台 WorkManager 属后续阶段。
- 不把现有备份文件改造成可写的“最新共享快照”。
- 不同步当前备份范围明确排除的 WebDAV/AI 凭证、备份口令、应用锁、备份目录、日志、AI 聊天历史和设备授权等设备专属数据。

## 用户可见语义

### 设置互斥

新增“自动同步”设置。它与现有“自动上传到 WebDAV”互斥：

- 开启自动同步时，在同一持久化操作中关闭自动上传。
- 开启自动上传时，在同一持久化操作中关闭自动同步。
- 两个开关不分别作为最终真相保存；新增一个 `backupTransportMode`（`manual`、`autoUpload`、`autoSync`）作为规范值，并保留旧键仅作迁移兼容。写入模式时使用带校验和的单值记录；启动时若发现旧键与规范值不一致，按规范值修复并记录日志。
- 手动“立即上传”和手动“从 WebDAV 恢复”始终可用；它们不等于自动同步。
- 自动同步的状态、最近成功时间、待上传变更数、待处理冲突数和最近错误在设置页可见。

### 加入共享账本

不增加邀请流程。用户在新设备输入相同 WebDAV 配置，先手动从 WebDAV 恢复现有备份，再开启自动同步。相同 WebDAV 账号对同步目录拥有相同读写权限；无法单独撤销某个设备或限制某个账本成员。

### 手动恢复与同步

“从 WebDAV 恢复”仍是现有整库覆盖操作。若自动同步已开启，恢复前必须显示待上传 outbox、未决冲突和将被覆盖的数据摘要；用户只能选择“先完成同步后恢复”或“确认覆盖并重置同步状态”。确认覆盖时取消未上传 outbox，清空 applied、scan、shadow，按新的本地内容建立基线，不把旧事件重新上传；远端历史事件不删除，下一次全量扫描仍可发现它们并按基线规则处理。恢复过程不自动打开或关闭自动同步模式。

### 冲突

- 不同设备新增的记录合并保留。
- 同一实体的并发编辑保留两个版本，并在同步状态中显示冲突数量。
- 删除与编辑并发也保留两个版本，不用“缺行”推断删除。
- 用户选择版本后写入一条新的决议事件；其他设备收到该事件后收敛到同一结果。
- 冲突页必须展示实体类型、账本、两个版本的字段差异、来源设备和时间/顺序信息，并提供保留版本 A、保留版本 B、取消三种结果。未处理冲突不能阻止继续记账。

## 数据边界

同步事件作用域为整个导出数据集合，而不是当前账本：所有 `ledgerBooks` 及其关联实体、`activeBookId`、`profile` 和已进入导出的显示/偏好字段均参与同步。语言、提醒、备份目录、日志、AI 聊天和凭证等当前未进入备份的数据仍由本机保留。实现时从 `exportDataJson()` 建立有测试保护的显式白名单，新增或删除备份字段时必须同步更新该白名单，禁止按“整份 JSON”自动推断。

首版白名单逐键固定为：`ledgerBooks`、`activeBookId`、`entries`、`accounts`、`accountGroups`、`categories`、`tags`、`attachments`、`recurringRules`、`exchangeRates`、`monthlyBudgets`、`categoryBudgets`、`dailyBudgets`、`budgetCycleStartDays`、`profile`、`themePreference`、`assetCoverUrl`、`hapticsEnabled`、`assetAccountViewMode`、`collapsedAssetSections`、`assetAccountOrders`、`assetSectionOrders`、`homePanels`、`reportPanels`、`defaultAccountIds`、`fabActionMode`、`amountForceTwoDecimals`、`currencyFractionStyle`、`moneyUnitStyle`、`hideUnitInSingleCurrency`、`autoSuggestEnabled`、`showRunningBalance`、`homeTrendConfig`、`userWidgetDefinitions`。`activeBookId` 按用户要求同步；语言、提醒和备份目录等不在该列表。

为避免不同账本互相覆盖，事件必须带实体作用域。账本级设置（例如主题、面板和排序）作为独立可冲突实体；预算 map 按单个键拆分为事件。交易、退款、附件和为其服务的汇率仍须保持现有聚合保存的跨表原子边界。

依赖列表顺序不能依赖当前数组位置。对 `ledgerBooks`、`accounts`、`accountGroups`、`categories`、`tags`、`attachments` 和 `recurringRules` 的排序变化使用独立的 order 实体（带稳定 position token）；如果旧模型没有持久化顺序字段，投影阶段从当前列表顺序生成 token，并在并发移动时保留两个 order 版本供选择。

## 协议与远端布局

同步协议独立于备份协议（备份仍为 zip 或加密信封）。WebDAV 目录使用追加式不可变事件文件：

```text
verifin-sync/v1/events/<deviceId>/<sequence>-<operationId>.vfsync
verifin-sync/v1/blobs/<sha256>
verifin-sync/v1/snapshots/<snapshotId>.enc   # 可选，只作加速
```

- 每个事件文件只写一次，文件名包含设备内单调序列和全局唯一 operationId，重复 PUT 必须幂等；若同名文件已存在但内容 hash 不同，视为设备序列/凭据碰撞，停止该设备上传并提示用户，不覆盖原文件。
- 事件正文至少包含 `protocolVersion`、数据作用域、实体类型/ID、操作类型、实体版本、payload hash、删除标记和必要的父引用。
- 有备份加密口令时，事件/批次和附件 blob 均沿用现有加密原语；没有口令时沿用现有明文行为。同步密钥不另行引入。启用同步前各设备必须配置相同的现有备份加密口令（或全部为空）；事件头带不可逆的 key fingerprint，不带口令。fingerprint 不匹配时暂停应用远端事件并提示用户修正，绝不尝试明文降级。首版不支持在线轮换口令；改变口令前必须暂停同步、完成 outbox 上传或导出备份，再在所有设备设置新口令并重新启用。
- `blobs` 使用内容寻址保存附件，事件只引用 hash；附件缺失时先下载校验，再提交引用它的实体。
- 事件文件是权威数据。索引或快照丢失时可以重新扫描事件；不能按现有自动备份 retention 删除事件。快照清理必须等所有已知设备确认对应事件后再做，首版不做垃圾回收。

当前 WebDAV 客户端只有 `MKCOL`、`PUT`、`GET`、`PROPFIND`、`DELETE`，没有可靠的 ETag/If-Match/LOCK。因此首版不依赖条件写或锁；目录发现实现逐级 `PROPFIND Depth:1`，逐级创建 `events/<deviceId>`、`blobs`、`batches` 目录，并支持分页/重复扫描。路径按 URL segment 编码，不能把包含 `/` 的整段路径交给 `Uri.encodeComponent` 后再拼接。事件、commit 和 blob 扩展名必须被列表逻辑明确接受；附件下载/上传采用流式分块、大小上限和 hash 校验，失败保留 pending/outbox，不使用无上限 `readBytes()`。

## 本地状态与版本

新增设备级持久化 `deviceId` 和单调事件序列；每次本地变更生成不可变 `operationId`。每个事件携带 dotted version vector（本次 `deviceId + sequence` 以及生成时已知的各设备最大 sequence）以判断因果先后和真正并发；HLC 只用于用户可见时间和稳定排序，不参与覆盖并发版本。同版本使用 `(logicalTime, deviceId, operationId)` 确定性展示排序。

新增同步元数据表/仓储边界，至少包含：

- `sync_shadow`：当前导出白名单投影的规范化 hash/版本，用于捕获 SQLite 与 KV 的本地变化；
- `sync_entities` / `sync_entity_versions`：实体当前版本集合、因果上下文、payload hash、删除 tombstone 和冲突关联；
- `sync_outbox`：待上传事件、上传状态和重试信息；
- `sync_applied_ops`：已应用 operationId 去重；
- `sync_pending`：等待父实体、附件或完整批次的远端事件；
- `sync_scan_state`：每设备已连续确认的 sequence、高水位 gap 集合、全量扫描时间和同步错误状态；
- `sync_apply_journal`：等待写入 KV 的变更批次和完成标记。

`SyncProjection` 把当前 `exportDataJson()` 白名单投影成规范化实体 map，并与 `sync_shadow` 比较生成 upsert/delete 事件。Controller 的所有 SQLite 保存入口、所有 KV 偏好写入口和恢复/重置入口都经过统一的 `SyncChangeTracker`；无法统一拦截的旧写入口必须在本阶段收口，否则不得开放自动同步。应用启动、回前台及变更防抖时还会执行一次完整比较，因此进程在上传前退出仍能在下次启动补出 outbox。删除必须显式写 tombstone，不能由远端某次扫描“缺少文件”推断。预算按键、偏好按字段或逻辑组拆分，避免无关字段互相覆盖。

远端账目和同步元数据在同一个 SQLite 事务中提交。KV 偏好无法参加 SQLite 事务，因此使用可恢复的 `sync_apply_journal`：先在 SQLite 记录待应用 KV 值、目标 hash 和事件批次状态，再按固定顺序 `writeAndFlush` KV，全部成功后标记完成；进程重启时优先重放未完成 journal。若 KV 写入中途失败，重放使用目标值幂等覆盖，不把半批状态发布为已应用。远端应用期间更新 `sync_shadow` 并抑制相同 payload 被重新识别为本地事件。

所有本地变更先写业务数据，再在同一操作链中写 shadow/outbox；若业务写成功而 outbox 写失败，启动时的完整投影比较必须补发事件。远端批次使用事务状态 `prepared -> applied`，只有业务表、同步元数据和 KV journal 都完成后才推进 applied/cursor。

## 合并规则

1. 新增实体取并集；相同 ID 的两个版本若一方的 dotted version vector 包含另一方，则较新的因果后继替代前序；若双方互不包含，则创建冲突记录并保留双方 payload。
2. 用户决议事件拥有新的版本并覆盖冲突状态；决议前双方版本不可被清理。
3. 删除是实体版本的一种，删除与编辑并发时保留删除和编辑版本，用户决议后才形成最终 tombstone 或实体。
4. 父分类、账户、账本等依赖尚未到达时，事件进入 `sync_pending`，待依赖满足后重放；不能回退到列表首项或自动改写用户引用。
5. 远端合并结果与交易、退款、附件、汇率的现有校验一起在单个 SQLite 事务中提交；失败则整批不提交且保留事件待重试。
6. 应用远端事件后只记录 `applied_ops`，不能把同一变更重新作为本地事件上传。

### 聚合批次

交易、退款、附件和汇率等必须原子提交的变更不拆成可独立生效的实体事件。一次用户保存生成一个 `batchId`，包含事件清单、父引用、附件 hash 和 payload hash；先上传不可变事件文件及附件，再上传同目录的 `batchId.commit` 完成标记。远端只应用同时拥有完整清单、所有附件和 commit 标记的批次；缺件或半批进入 pending。commit 标记也不可覆盖，重传必须幂等。派生字段 `LedgerEntry.refundedBaseAmount` 不作为独立可竞争字段，应用完整批次后统一按已到账退款重算。

## 同步流程与触发

一次同步按以下顺序执行，并由全局互斥锁防止并发运行：

1. 读取本机 outbox，准备并幂等上传尚未上传的事件、批次清单、commit 标记和附件。
2. 按设备目录递归扫描同步目录，发现其他设备事件；下载本机未见的 operationId。扫描状态只推进“连续无 gap 的 sequence”；迟到或分页遗漏的 sequence 保留在 gap 集合，下一次继续扫描。服务器不支持递归或分页时退回从根目录全量重扫，不能依赖单次 index 或固定文件数量。
3. 校验文件大小/hash，解密并验证协议版本和作用域。
4. 按版本顺序合并；不满足依赖的事件进入 pending。
5. 将完整批次的合并结果通过一次 SQLite 事务写入，并把 KV 变更写入 `sync_apply_journal`；KV 全部刷盘后才记录 applied/连续高水位。
6. 上传本机因冲突决议或远端合并产生的新事件；更新设置页状态。

首版触发点：应用冷启动、回到前台、任一本地变更后短暂防抖、设置页“立即同步”。网络失败采用有限重试和指数退避；失败不阻止本地记账，outbox 保留待下次同步。首版不在后台定时唤醒，不把“每隔 N 小时自动备份”复用为同步定时器。

同步状态和错误持久化在 `sync_scan_state`，包括最后成功时间、最后错误稳定码、重试次数、待上传数、待处理冲突数和当前模式。网络恢复或回前台时按 gap/outbox 重试；用户可在设置页清除错误状态，但不能删除未上传事件。

## 兼容与迁移

- 现有 `verifin-auto-*` 和 `verifin-backup-*` 文件继续由备份/恢复流程处理，自动同步只读写 `verifin-sync/v1/`。
- 新设备第一次开启同步前必须已有可识别的账本数据。启用向导先冻结本机同步写入，完成一次远端全量扫描并记录每设备连续高水位；远端为空时，从当前恢复数据生成一次基线批次并上传 commit；远端非空时，先按事件/批次重建远端状态，再按实体 hash 与本地恢复数据比较：相同状态建立 shadow；不同状态生成“加入时冲突”，保留本地与远端版本。记录的高水位只覆盖扫描完成前已存在的 sequence，扫描开始后到达的事件下一轮正常处理，不能重复应用历史或把并发写入误判为基线。
- 数据库迁移必须提升 schema version、注册迁移段，并更新 migration matrix、repository contract、model round-trip 及同步专用测试。
- 旧版本客户端看不懂同步目录时应忽略它，不得把同步事件当普通备份导入。

## 错误、安全与隐私

- WebDAV 失败、协议不兼容、哈希不匹配、解密失败和事务失败均记录隐私友好日志；不记录密码、完整账目或原始密文。
- 同一账号即拥有同步目录的全部读写能力。WebDAV 服务器可见文件数量、大小和访问时间；首版接受这一元数据暴露，事件正文在配置口令时加密。
- 自动同步不删除远端事件，不因 retention 设置清理同步历史。
- 任何远端数据覆盖前都经过 schema/引用/金额三层校验；无法验证的事件留在 pending/错误状态并提示用户。

## 验收标准

1. 开启一个开关会原子关闭另一个开关，重启后状态保持互斥。
2. 两台设备分别离线新增交易，联网同步后两笔均存在；重复同步不产生重复记录。
3. 两台设备离线编辑同一实体，联网后两版本均可查看，选择任一版本后两台设备最终一致。
4. 删除与编辑并发不会复活或静默丢失实体，冲突决议可审计。
5. 设备离线记账后，outbox 保留；网络恢复并回前台后自动上传并拉取远端变更。
6. 附件按 hash 去重，缺 blob 或 hash 错误不会提交引用它的交易。
7. 自动同步不上传整份自动备份、不触发备份 retention 清理；现有手动上传/恢复测试继续通过。
8. 个人资料和已纳入备份的偏好按同样规则同步，WebDAV 凭证、备份口令、应用锁、日志等设备专属数据不离开本机。
9. 完成 `dart format .`、`flutter analyze`、`flutter test`，并对 SQLite 迁移、真实 WebDAV 测试替身、Android 前后台与 release/R8 行为补充验证。

## 分阶段交付

### M0：协议与本地基础

确定事件 JSON、dotted version vector、冲突记录和设备标识；新增 schema/迁移、deviceId、shadow/outbox/applied/pending/journal 元数据；先做本地双设备模拟测试。

### M1：WebDAV 前台同步

实现递归发现、幂等事件 PUT、下载校验、附件 blob、首次引导与同步状态；这一阶段只开放内部测试入口，不提前暴露不完整的自动同步开关。

### M2：冲突处理与完整实体

接入全部导出字段的投影与合并，完成冲突列表/详情/决议、删除 tombstone、依赖乱序、交易聚合原子提交、预算按键同步、互斥设置、正式触发和同步状态 UI；全部验收通过后才开放自动同步开关。

### M3：可靠性与设备验证

加入退避、限流、断点/大附件流式处理和可选快照；再评估 WorkManager；用 Android release/R8 真机验证前后台、进程被杀和恢复路径。

## 待实现时保持的边界

这不是实时云同步，也没有成员权限。任何“同一 WebDAV 账号”的设备都可修改全部同步数据；实现不能通过 UI 暗示更强的一致性、权限或后台保证。
