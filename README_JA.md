<p align="center">
  <img src="GestaltX/Assets.xcassets/AppIcon.appiconset/AppIcon.png" alt="GestaltX" width="112" height="112">
</p>

<h1 align="center">GestaltX</h1>

[![Version](https://img.shields.io/badge/version-1.0.6-blue)](https://github.com/huamidev/GestaltX)
[![Platform](https://img.shields.io/badge/iOS-27.x-black?logo=apple)](#互換性)
[![SwiftUI](https://img.shields.io/badge/Swift-SwiftUI-orange?logo=swift)](https://github.com/huamidev/GestaltX)
[![License](https://img.shields.io/badge/license-GPLv3-blue)](LICENSE)

[English](README.md) · [简体中文](README_ZH-CN.md) · [日本語](README_JA.md) · [한국어](README_KO.md)

iPhone と iPad 向けの MobileGestalt エディターです。開発者は [huamidev](https://github.com/huamidev) です。

## 機能

| カテゴリ | プリセットとツール |
| --- | --- |
| ディスプレイ | Dynamic Island の機能とレイアウト、常時表示ディスプレイ (Always-On Display)、AOD Vibrancy、高輝度 AOD、AOD フリップブック、HDR 写真表示、壁紙の視差効果、Liquid Glass の低電力レンダリング、実験的な PWM および DisplayPort フラグ |
| デバイス | モデル名、起動/シャットダウン音、充電上限、タップしてスリープ解除、カメラコントロールの設定、アクションボタンの設定、衝突事故検出 SOS、Audio Mix、空間 FaceTime オーディオ |
| iPad | Apple Pencil の設定、ステージマネージャの機能、iPad アプリの互換性 |
| インテリジェンス | 独立した地域コードのオプション、Apple Intelligence の機能フラグ、オンデバイス Siri、Audio Intelligence、Personal Translator、写真のクリーンアップ、手書き合成 (Handwriting Synthesis)、常時待ち受けの Hey Siri、および中国本土モデルのデバイスで有効化を試みるための販売地域オプション |
| 詳細 | Apple 社内向けの機能フラグ、有効化時に個別の確認が必要なシステム全体の InternalBuild フラグ、内部設定バンドル、Security Research Device フラグ |
| フィールドエディター | `CacheExtra` フィールドの読み取り、検索、追加、編集、削除。ローカル plist のインポート/エクスポート。String、Integer、Real、Boolean、Data、Date、Array、Dictionary の値に対応 |
| 変更 | 自動読み取りと手動での再読み込み、変更前/変更後を確認できるステージング、検証付きの書き込み、プリセットごとの復元 |
| バックアップ | デバイスの編集前に自動で初期バックアップを作成、書き込みのたびにバックアップ、元の値の記録。開く、エクスポート、復元、削除に対応 |
| ログとリスプリング | エクスプロイトの各段階の実際のログと、NeoSpring による手動リスプリング |

通常、AI の有効化を試すには地域コードを変更するだけで十分で、Sales Region を変更する必要はありません。Region Code で United States を選択すると、`RegionCode` が `LL` に設定され、販売地域のサフィックスはそのまま維持されます。China (Mainland)、Hong Kong、Taiwan、Japan、United Kingdom も選択できます。Sales Region と Region Code は同時に適用できます。その場合、販売サフィックスは Sales Region に、コードは Region Code に従います。

*以前に Sales Region を変更したことがある場合は、まずデバイス本来の販売地域に戻して適用してください。*

プリセットを無効にするか、その Revert ボタンを使うと、記録されている元の値と型が復元されます。元々存在しなかったキーは削除されます。古い変更に元の値の記録がない場合は、それらのフィールドが追加されたものだとわかっているときに限り Remove Added Fields を使用してください。

プリセットは機能フラグを変更するものであり、実際の効果はデバイスと OS によって異なります。中国本土モデルのデバイスでは、Apple Intelligence と地域のオプションを使って有効化を試すことができますが、利用できるかどうかはモデル、OS のバージョン、Apple のサービスにも左右されます。

## 互換性

**iOS / iPadOS 27.x** に対応しています。**iOS / iPadOS 26.x では、オンデバイスでの MobileGestalt へのアクセスには対応していません。** [worse_query](https://github.com/forcequitOS/worse_query) を利用しています。SystemGroup へのアクセスには iOS 27 が必要で、利用できる機能はデバイスと OS によって異なります。ローカルの plist の編集にも対応しています。

署名には、使用可能な App Group を少なくとも 1 つ含む証明書とプロビジョニングプロファイルが必要です。アプリとそれに埋め込まれた共有拡張機能は、少なくとも 1 つの **共通の App Group** で署名し、再署名の際も拡張機能を残してください。どちらのプロセスも、実際に署名された App Group を実行時に検出します。配布されている IPA には、これらのエンタイトルメントを埋め込んだ ad-hoc 署名が施されているため、SideStore や AltStore が再署名時にそれらを検出できます。開発者証明書では署名されていません。

## ダウンロード

IPA は [Releases](https://github.com/huamidev/GestaltX/releases/latest) からダウンロードしてください。
iOS 27 の Safari でダウンロードが不完全になるという報告があります。
破損や解凍エラーが表示された場合は、数回ダウンロードし直してください。
改善しない場合は別のブラウザをお試しください。原因はまだ確認されていません。

## plist をインポートする

ファイル App などのアプリで MobileGestalt の plist を選択し、**Share** をタップして **GestaltX** を選びます。共有拡張機能が渡されたファイルを読み取り、共有の App Group を通じてアプリに引き渡します。自動的に開かない場合は GestaltX に戻ってください。アプリは、GestaltX からエクスポートしたファイルに含まれるデバイス固有の証明、またはこのデバイスから取得した少なくとも 2 つの固有識別子を確認したうえで、インポートの確認を求めます。検証できないファイルは拒否されます。以前にインポートしたファイルが、デバイスの識別の基準として使われることはありません。

元の plist の中には、デバイスの固有識別子を含まないものもあります。その場合は、まずこのデバイス上の GestaltX からコピーをエクスポートしてください。その検証キーはこのデバイス専用のキーチェーンに保存され、ファイルに含まれることはありません。

共有されたファイルは、起動時とフォアグラウンドに戻ったときに確認されます。保留中の編集は、保存するか破棄するまで保持されます。確認済みのインポートはローカルドキュメントとして開かれます。**MG Control** では、型付きのキーと値の追加、編集、名前変更、削除ができます。検証済みのファイルをこのデバイスに復元するには **Restore Imported Plist** を使用します。復元には一致するシステムキャッシュのレイアウトと追加の確認が必要で、現在のファイルをバックアップしてから書き込みを検証します。復元後はデバイスを再起動してください。

## 対応言語

GestaltX は iOS の言語設定に従い、英語をデフォルトおよびフォールバックとして使用します。ペルシア語では右から左へのレイアウトにも対応しています。

| 言語 | ロケール |
| --- | --- |
| English | `en` |
| 简体中文 — 簡体字中国語 | `zh-Hans` |
| 繁體中文（台灣）— 繁体字中国語 (台湾) | `zh-Hant-TW` |
| 繁體中文（香港）— 繁体字中国語 (香港) | `zh-Hant-HK` |
| Tiếng Việt — ベトナム語 | `vi` |
| Русский — ロシア語 | `ru` |
| فارسی — ペルシア語 | `fa` |
| 한국어 — 韓国語 | `ko` |
| Español — スペイン語 | `es` |
| 日本語 | `ja` |

## クレジット

- [forcequitOS / Taj C — worse_query](https://github.com/forcequitOS/worse_query)
- [neonmodder123](https://github.com/neonmodder123)
- [skadz108](https://github.com/skadz108)
- [rooootdev — NeoSpring](https://github.com/rooootdev/neospring)
- [Nouvborne — Ketamine](https://github.com/Nouvborne/Ketamine)
- [PoomSmart — MGKeys](https://github.com/PoomSmart/MGKeys)
- [leminlimez — Nugget](https://github.com/leminlimez/Nugget)
- [rooootdev — mond](https://github.com/rooootdev/mond)
- [frs0n — GestaltEdit](https://github.com/frs0n/GestaltEdit)

## 免責事項

セキュリティ研究および教育目的に限ります。自分が所有している、または管理する権限を持つデバイスでのみ使用してください。

変更を加える前にデータをバックアップしてください。MobileGestalt を変更すると、システムが不安定になったり、デバイスの復元が必要になったりする場合があります。適用した変更とその結果生じるリスクについては、ご自身の責任となります。

## ライセンス

[GNU GPL v3](LICENSE) · Copyright © 2026 huamidev.

## Star 履歴

<a href="https://www.star-history.com/#huamidev/GestaltX&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=huamidev/GestaltX&amp;type=Date&amp;theme=dark" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=huamidev/GestaltX&amp;type=Date" />
    <img width="480" alt="GestaltX の Star 履歴" src="https://api.star-history.com/svg?repos=huamidev/GestaltX&amp;type=Date" />
  </picture>
</a>
