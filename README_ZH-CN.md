<p align="center">
  <img src="GestaltX/Assets.xcassets/AppIcon.appiconset/AppIcon.png" alt="GestaltX" width="112" height="112">
</p>

<h1 align="center">GestaltX</h1>

[![Version](https://img.shields.io/badge/version-1.0.6-blue)](https://github.com/huamidev/GestaltX)
[![Platform](https://img.shields.io/badge/iOS-27.x-black?logo=apple)](#兼容性)
[![SwiftUI](https://img.shields.io/badge/Swift-SwiftUI-orange?logo=swift)](https://github.com/huamidev/GestaltX)
[![License](https://img.shields.io/badge/license-GPLv3-blue)](LICENSE)

[English](README.md) · [简体中文](README_ZH-CN.md) · [日本語](README_JA.md)

适用于 iPhone 和 iPad 的 MobileGestalt 编辑工具，由 [huamidev](https://github.com/huamidev) 开发。

## 功能

| 分类 | 预设与工具 |
| --- | --- |
| 显示 | 灵动岛功能标记与布局、全天候显示、AOD 色彩、高亮度 AOD、AOD 翻页组件、HDR 照片显示、壁纸视差、液态玻璃低性能渲染，以及实验性的 PWM 与 DisplayPort 标记 |
| 设备 | 机型名称、开关机提示音、充电上限、轻点唤醒、相机控制设置、操作按钮设置、车祸检测 SOS、音频混音、FaceTime 空间音频 |
| iPad | Apple Pencil 设置、台前调度功能标记、iPad 应用兼容性 |
| 智能 | 独立的地区代码选项、Apple 智能功能标记、端侧 Siri、音频智能、个人翻译、照片消除、手写合成、常听 Hey Siri 及销售地区选项；国行设备可尝试开启 AI |
| 高级 | Apple 内部功能标记、需单独确认启用的系统全局 InternalBuild 标记、内部设置包、安全研究设备标记 |
| 字段编辑 | 读取、搜索、添加、编辑与删除 `CacheExtra` 字段；本地 plist 导入导出；支持字符串、整数、浮点数、布尔值、数据、日期、数组和字典 |
| 更改管理 | 启动自动读取、手动重新读取、暂存更改前后对比、写入验证、逐项还原 |
| 备份 | 首次读取自动备份、每次写入前备份、原值记录；打开、导出、恢复和删除 |
| 日志与注销 | 实际漏洞利用过程日志、手动 NeoSpring 注销 |

通常只需修改地区代码即可尝试启用 AI，无需更改销售地区。“地区代码”选择“美国”时仅将 `RegionCode` 设为 `LL`，保留销售地区后缀，也可选择中国大陆、香港、台湾、日本或英国。销售地区与地区代码可以一起应用：后缀按销售地区设置，代码按地区代码设置。

*之前修改过销售地区的用户，请先改回设备原本的销售地区并应用。*

停用预设或点击该项“还原”，会恢复已记录的原值及类型；原本不存在的字段会被删除。旧版修改若缺少原值记录，请仅对确认是后来添加的字段使用“移除新增字段”。

预设修改的是功能标记，实际效果取决于设备与系统。国行设备可通过 Apple 智能与地区选项尝试启用 AI，实际可用性还取决于机型、系统版本及 Apple 服务。

## 兼容性

支持 **iOS / iPadOS 27.x**。**iOS / iPadOS 26.x 不支持本机 MobileGestalt 访问。** 基于 [worse_query](https://github.com/forcequitOS/worse_query)。SystemGroup 访问需要 iOS 27，功能可用性因设备与系统而异，同时支持本地 plist 编辑。

签名所用的证书及描述文件必须提供至少一个可用的 App Group。主应用和内置分享扩展必须签入至少一个**相同的 App Group**，重签时请保留分享扩展。两者均会在运行时读取实际签名中的 App Group。发布的 IPA 使用 ad-hoc 签名嵌入这些 entitlements，便于 SideStore、AltStore 在重签时识别，不使用开发者证书。

## 下载

请在 [Releases](https://github.com/huamidev/GestaltX/releases/latest) 下载 IPA。
部分用户反馈，iOS 27 上使用 Safari 下载的文件可能不完整。
如果提示文件损坏或无法解压，可重新下载几次；仍有问题时换用其他浏览器。
目前尚未确认具体原因。

## 导入 plist

在“文件”或其他 App 中选中 MobileGestalt plist，点击**分享**，再选择 **GestaltX**。分享扩展会直接读取收到的文件，并通过共同的 App Group 交给主应用。如未自动打开，请返回 GestaltX。应用会验证 GestaltX 导出文件的本机凭证，或将文件中的至少两个唯一设备标识与本机信息比对，通过后弹窗确认导入。无法核验的文件均拒绝导入，不会把之前导入的文件当成本机身份依据。

部分原始 plist 不含唯一设备标识，请先在本机通过 GestaltX 导出一份副本。校验密钥只保存在本机钥匙串，不随文件导出。

应用会在启动和回到前台时检查分享文件。当前有未保存更改时，会等待你保存或放弃后再导入。确认导入的文件作为本地文档打开。“**MG 控制**”支持新增、修改、重命名和删除不同类型的键值。点击“**恢复导入的 plist**”可将已核验的文件恢复到本机；恢复时会核对系统缓存布局，经过二次确认后先备份当前文件，再写入并验证。完成后请重启设备。

## 语言支持

GestaltX 跟随 iOS 的语言设置，默认及回退语言为英语。波斯语已适配从右向左布局。

| 语言 | 语言代码 |
| --- | --- |
| English（英语） | `en` |
| 简体中文 | `zh-Hans` |
| 繁體中文（台灣） | `zh-Hant-TW` |
| 繁體中文（香港） | `zh-Hant-HK` |
| Tiếng Việt（越南语） | `vi` |
| Русский（俄语） | `ru` |
| فارسی（波斯语） | `fa` |
| 한국어（韩语） | `ko` |
| Español（西班牙语） | `es` |
| 日本語（日语） | `ja` |

## 鸣谢

- [forcequitOS / Taj C — worse_query](https://github.com/forcequitOS/worse_query)
- [neonmodder123](https://github.com/neonmodder123)
- [skadz108](https://github.com/skadz108)
- [rooootdev — NeoSpring](https://github.com/rooootdev/neospring)
- [Nouvborne — Ketamine](https://github.com/Nouvborne/Ketamine)
- [PoomSmart — MGKeys](https://github.com/PoomSmart/MGKeys)
- [leminlimez — Nugget](https://github.com/leminlimez/Nugget)
- [rooootdev — mond](https://github.com/rooootdev/mond)
- [frs0n — GestaltEdit](https://github.com/frs0n/GestaltEdit)

## 免责声明

本项目仅供安全研究与学习交流，请仅在本人持有或已获授权的设备上使用。

修改前请备份数据。修改 MobileGestalt 可能导致系统不稳定，严重时需要恢复设备。使用者须自行承担所选修改及其带来的风险。

## 许可证

[GNU GPL v3](LICENSE) · Copyright © 2026 huamidev。

## Star History

<a href="https://www.star-history.com/#huamidev/GestaltX&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=huamidev/GestaltX&amp;type=Date&amp;theme=dark" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=huamidev/GestaltX&amp;type=Date" />
    <img width="480" alt="GestaltX Star 增长历史" src="https://api.star-history.com/svg?repos=huamidev/GestaltX&amp;type=Date" />
  </picture>
</a>
