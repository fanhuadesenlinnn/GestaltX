# 更新日志

[English](CHANGELOG.md) | 简体中文

## [1.0.7] - 2026-11-13

构建号 `11130112`。

### 修复

- 修复 iOS 27.3 无法定位设备容器的问题，壁纸与「App 启动图」恢复可用。

## [1.0.6] - 2026-11-12

构建号 `11122300`。

### 新增

- 新增「系统设置」，支持自定义锁屏底部文字，即时生效，无需重启设备。
- 新增「壁纸设置」，支持导入、添加和移除壁纸包，可通过分享扩展导入 `.tendies`、`.zip` 文件。
- 新增「应用启动图」，支持自选照片、将当前启动图以原尺寸保存到相册、自动备份和还原。
- 新增日语，基于 [@kagithu](https://github.com/kagithu) 提供的翻译补齐缺失文案（[#124](https://github.com/huamidev/GestaltX/issues/124)）。
- 补充 iPhone Air 灵动岛布局（[#105](https://github.com/huamidev/GestaltX/pull/105)）。

### 调整

- 为「放弃更改」补充图标；没有待处理更改时，「应用更改」和「放弃更改」统一置灰。

### 修复

- 保留设备原有的端侧 Siri 能力值，避免统一覆盖后导致 Apple Intelligence Siri 退回旧版界面（[#102](https://github.com/huamidev/GestaltX/pull/102)、[#98](https://github.com/huamidev/GestaltX/issues/98)）。
- 完善分享导入的取消处理与临时文件清理。

**完整变更**：[v1.0.5...v1.0.6](https://github.com/huamidev/GestaltX/compare/v1.0.5...v1.0.6)

## [1.0.5] - 2026-11-11

构建号 `11111140`。

### 新增

- 新增西班牙语，应用现支持 9 种语言与地区设置（[#97](https://github.com/huamidev/GestaltX/pull/97)）。
- 新增 iPhone Air 机型预设（[#92](https://github.com/huamidev/GestaltX/pull/92)）和日文 README（[#83](https://github.com/huamidev/GestaltX/pull/83)）。

### 调整

- 关于页面的支持系统改为 iOS / iPadOS 27.x。仍可在 26.x 上安装，
  但会提示不支持本机 MobileGestalt 访问。
- 更新韩语翻译（[#84](https://github.com/huamidev/GestaltX/pull/84)），修复繁体中文等语言中混入其他语言的问题（[#61](https://github.com/huamidev/GestaltX/pull/61)）。
- 中文的 Photos Clean Up 预设统一改为“照片消除”。
- 修正 Internal Build 名称，开启该系统全局标记前增加确认（[#60](https://github.com/huamidev/GestaltX/pull/60)）。

### 修复

- 访问设备时保留 App Group 原有缓存，避免影响共享同一组的其他应用（[#55](https://github.com/huamidev/GestaltX/pull/55)）。
- 还原灵动岛时同时恢复布局和功能标记，并保留其他已暂存的外观修改（[#58](https://github.com/huamidev/GestaltX/pull/58)）。
- 恢复原值时校验系统缓存代次和布局，区分无法取得的原值与原本不存在的字段，
  避免反复读取旧备份历史（[#65](https://github.com/huamidev/GestaltX/pull/65)、[#66](https://github.com/huamidev/GestaltX/pull/66)）。
- 恢复未发生变化的备份时不再重复写入设备（[#69](https://github.com/huamidev/GestaltX/pull/69)）；备份删除失败后可重试（[#70](https://github.com/huamidev/GestaltX/pull/70)），
  本地备份替换后清除继承的设备归属状态（[#64](https://github.com/huamidev/GestaltX/pull/64)）。
- 已核验的设备备份在导出时携带本机校验凭证（[#59](https://github.com/huamidev/GestaltX/pull/59)）；
  分享完成或取消后清理临时导出文件（[#62](https://github.com/huamidev/GestaltX/pull/62)）。
- 直接打开的文件会先保存再等待导入确认（[#63](https://github.com/huamidev/GestaltX/pull/63)），文件协调读取移至后台（[#75](https://github.com/huamidev/GestaltX/pull/75)）。
  临时访问失败（[#74](https://github.com/huamidev/GestaltX/pull/74)）或单个 App Group 无法访问（[#71](https://github.com/huamidev/GestaltX/pull/71)）时，不再阻塞其他排队文件。
- 加强共享导入的容器边界和符号链接检查，限制文件名元数据大小，
  清理遗留文件时避开正在写入的内容（[#72](https://github.com/huamidev/GestaltX/pull/72)、[#73](https://github.com/huamidev/GestaltX/pull/73)、[#76](https://github.com/huamidev/GestaltX/pull/76)）。
- 写入系统前拒绝设备身份字段变更（[#67](https://github.com/huamidev/GestaltX/pull/67)），校验重复的缓存描述项（[#56](https://github.com/huamidev/GestaltX/pull/56)），
  修复未修改的 NaN 值被误判为发生变化的问题（[#68](https://github.com/huamidev/GestaltX/pull/68)）。

### 下载与签名

- 部分用户反馈，iOS 27 上使用 Safari 下载的文件可能不完整。
  如果提示 IPA 损坏或无法解压，可重新下载几次；仍有问题时换用其他浏览器。
  目前尚未确认是否由 Safari 或 iOS 本身导致。
- 重签所用证书与描述文件须包含至少一个可用 App Group。
  请保留分享扩展，并为主应用和扩展配置同一个 App Group。

**完整变更**：[v1.0.4...v1.0.5](https://github.com/huamidev/GestaltX/compare/v1.0.4...v1.0.5)

## [1.0.4] - 2026-11-10

构建号 `11101436`。

### 新增

- **设备 → 预设**新增 WAPI 预设：可关闭 WAPI 监管标志，或恢复已记录的原值。
  缓存中的布尔值从设备自身的 MobileGestalt 镜像解析，而不是硬编码槽位（#30）。
- 为 WAPI 标志记录每台设备的原值。该值在编辑、App 重启、日志迁移后仍然保留，
  并与其他缓存选项一起恢复（#30）。
- 新增显示预设：高亮度始终显示、AOD 翻页组件及其条目数量、HDR 照片显示、
  壁纸视差控制，以及实验性的 PWM 和 DisplayPort 能力标记。
- 新增设备预设：车祸检测 SOS、音频混音、FaceTime 空间音频。
- 新增智能预设：端侧 Siri、音频智能、个人翻译、照片 Clean Up、手写合成、
  常听 Hey Siri。这些仍然只是能力标记，实际是否运行仍取决于硬件和地区。
- 新增韩语本地化，应用现支持 8 种语言（#24）。
- CI 现在会自动构建 ad-hoc 签名 IPA 并上传为 artifact；
  tag 和 Release 运行还会附加到对应 Release。

### 变更

- 附加选项和 WAPI 行现在直接显示在 **设备 → 预设** 中。
  已移除 About 版本号上的 10 连点隐藏解锁。
- 当前文档存在暂存修改时，打开和恢复操作会被禁用。请先保存或放弃修改，
  避免静默丢失更改（#37）。
- 版本号更新为 1.0.4（`CURRENT_PROJECT_VERSION` 11101436）。
  README 版本徽章和构建日期已同步更新。
- 所有新增的用户可见字符串均已本地化为 8 种语言
  （英语、简体中文、繁体中文（台湾）、繁体中文（香港）、越南语、俄语、
  波斯语、韩语）（#30、#38）。

### 修复

- 设备访问现在会在所有已签名的 App Group 之间回退，而不是只信任第一个。
  修复了使用包含多个 App Group 的证书签名时出现的
  `MobileGestalt access was denied` 错误（#47）。
- 字段编辑会保留完整的 64 位整数，包括大于 `Int64.max` 的无符号值。
  回读比较不再把 `UInt64.max` 与 `-1` 混为一谈（#31）。
- 打开字段但不修改直接应用时，不再重新解析显示文本，从而保留亚毫秒级
  `Date` 精度，以及数组和字典中的嵌套值（#34）。
- 应用机型名称或灵动岛布局预设时，畸形的 `ArtworkTraits` 值不再被替换或丢失。
  UI 会提示需要先在 MG Control 中修复该字段（#38）。
- 设备备份恢复会在任何写入前拒绝不同的 `CacheUUID`、`CacheVersion` 或
  `CacheData` 长度，不再恢复不兼容的缓存布局（#32）。
- 保存的备份在复用前会校验记录的大小和 SHA-256 摘要。
  没有摘要的旧备份仍然可以读取（#33）。
- 共享 plist 导入会拒绝 FIFO、socket、目录和符号链接，不再阻塞在特殊文件上，
  同时仍然接受普通文件（#35）。
- File Provider 导入会协调读取，占位文件会被物化，并发修改不会破坏读取结果
  （#39）。
- 取消分享扩展时会恢复卡住的 provider continuation，并取消底层 `Progress`，
  不再让扩展挂起（#36）。
- 拒绝或确认一个共享 plist 后，后续排队导入不再等待下一次前台事件。
  无效条目会被跳过，队列按顺序继续（#40）。
- 备份恢复会在创建恢复备份或日志记录前校验保存的布局，
  被拒绝的恢复不会产生副作用（#32）。

### 安全

- 备份完整性使用持久化的 SHA-256 摘要。同尺寸替换为另一个有效 plist 会被检测到
  （#33）。
- 收件箱扫描和导入使用 `O_NOFOLLOW` 打开文件，并要求是普通文件描述符，
  防止命名管道和符号链接攻击（#35）。

**完整变更**：[v1.0.3...v1.0.4](https://github.com/huamidev/GestaltX/compare/v1.0.3...v1.0.4)

[1.0.6]: https://github.com/huamidev/GestaltX/releases/tag/v1.0.6
[1.0.5]: https://github.com/huamidev/GestaltX/releases/tag/v1.0.5
[1.0.4]: https://github.com/huamidev/GestaltX/releases/tag/v1.0.4
