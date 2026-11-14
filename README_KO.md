<p align="center">
  <img src="GestaltX/Assets.xcassets/AppIcon.appiconset/AppIcon.png" alt="GestaltX" width="112" height="112">
</p>

<h1 align="center">GestaltX</h1>

[![Version](https://img.shields.io/badge/version-1.0.6-blue)](https://github.com/huamidev/GestaltX)
[![Platform](https://img.shields.io/badge/iOS-27.x-black?logo=apple)](#호환성)
[![SwiftUI](https://img.shields.io/badge/Swift-SwiftUI-orange?logo=swift)](https://github.com/huamidev/GestaltX)
[![License](https://img.shields.io/badge/license-GPLv3-blue)](LICENSE)

[English](README.md) · [简体中文](README_ZH-CN.md) · [日本語](README_JA.md) · [한국어](README_KO.md)

iPhone과 iPad용 MobileGestalt 편집기입니다. [huamidev](https://github.com/huamidev)가 개발했습니다.

## 기능

| 분류 | 프리셋과 도구 |
| --- | --- |
| 디스플레이 | Dynamic Island 지원 여부와 레이아웃, 상시표시형 디스플레이(AOD), AOD 색상 선명도, 고휘도 AOD, AOD 플립북, HDR 사진 표시, 배경화면 시차 효과, Liquid Glass 저전력 렌더링, 실험적인 PWM·DisplayPort 플래그 |
| 기기 | 모델명, 부팅·종료 알림음, 충전 한도, 탭하여 깨우기, 카메라 컨트롤 설정, 동작 버튼 설정, 충돌 감지 SOS, 오디오 믹스, FaceTime 공간 음향 |
| iPad | Apple Pencil 설정, 스테이지 매니저 지원 여부, iPad 앱 호환성 |
| 인텔리전스 | 판매 지역과 별도로 설정하는 지역 코드, Apple Intelligence 지원 플래그, 온디바이스 Siri, 오디오 인텔리전스, 개인 번역기, 사진 클린업, 손글씨 합성, 항상 'Siri' 듣기, 중국 본토 기기의 AI 활성화를 시도하는 판매 지역 옵션 |
| 고급 | Apple 내부 기능 플래그, 켜기 전에 별도 확인을 거치는 시스템 전체 InternalBuild 플래그, 내부 설정 번들, 보안 리서치 기기 플래그 |
| 필드 편집기 | `CacheExtra` 필드 읽기·검색·추가·편집·삭제, 로컬 plist 가져오기·내보내기, String·Integer·Real·Boolean·Data·Date·Array·Dictionary 자료형 지원 |
| 변경 사항 | 자동 읽기와 수동 다시 읽기, 적용할 변경 사항의 전후 값 비교, 저장 결과 검증, 프리셋별 복원 |
| 백업 | 기기 설정을 처음 수정하기 전 자동 백업, 매번 저장하기 전 백업, 원래 값 기록, 백업 열기·내보내기·복원·삭제 |
| 로그 및 리스프링 | 익스플로잇의 실제 진행 단계별 로그, NeoSpring을 이용한 수동 리스프링 |

AI 활성화는 보통 지역 코드만 바꿔서 시도할 수 있습니다. 판매 지역까지 바꿀 필요는 없습니다. **지역 코드**에서 미국을 선택하면 `RegionCode`가 `LL`로 바뀌고, 판매 지역을 나타내는 접미사는 그대로 유지됩니다. 중국 본토, 홍콩, 대만, 일본, 영국도 선택할 수 있습니다. **판매 지역**과 **지역 코드**를 함께 변경하면 접미사는 판매 지역 설정에 따라, 코드는 지역 코드 설정에 따라 바뀝니다.

*판매 지역을 바꾼 적이 있다면 기기의 원래 판매 지역으로 되돌린 뒤, 그 변경 사항부터 적용하세요.*

프리셋을 끄거나 **되돌리기**를 누르면 기록해 둔 원래 값과 자료형으로 돌아갑니다. 원래 없던 키는 삭제됩니다. 예전 변경 사항에 원래 값 기록이 남아 있지 않다면, 나중에 추가된 필드가 확실할 때만 **추가된 필드 제거**를 사용하세요.

프리셋은 시스템에 기능 지원 여부를 알리는 플래그를 바꿉니다. 실제 작동 여부는 기기와 OS에 따라 다릅니다. 중국 본토 기기에서도 Apple Intelligence와 지역 옵션으로 활성화를 시도할 수 있지만, 사용 가능 여부는 모델, OS 버전, Apple 서비스에 따라서도 달라집니다.

### Apple Intelligence, Face ID와 받아쓰기

[YumEdit 1.2.1 방식](https://github.com/H4CNPE/YumEdit/tree/v1.2.1)은 제품·보드·CPU 정보를 위장하지 않고 활성화를 시도합니다. **인텔리전스**의 **Apple Intelligence 기능**은 생성형 모델 플래그를 `1`로 설정하고, 별도의 **Siri AI 모드** 프리셋은 `SiriMode`를 `2`로 설정합니다. 둘 다 하드웨어 ID나 기기별 온디바이스 Siri 지원 설정은 건드리지 않습니다. 실험적인 플래그이므로 리소스 다운로드나 Apple Intelligence의 정상 작동을 보장하지는 않습니다. 이후 YumEdit은 활성화 절차를 실험적인 2단계 방식으로 바꿨습니다. GestaltX에는 하드웨어 정보를 임시로 위장하는 기능이 없습니다.

이전에 하드웨어 정보를 위장한 뒤 Face ID나 받아쓰기가 작동하지 않는다면, **백업 → 하드웨어 ID 복원**에서 변경 전 기기 백업을 선택하세요. 검증된 원본 plist를 가져온 다음 **인텔리전스 → 하드웨어 ID 복원**을 사용해도 됩니다. 아직 적용하지 않은 변경 사항은 먼저 저장하거나 취소하세요.

복구하려면 같은 기기에서 만든 검증된 백업이 필요합니다. `CacheData`, `CacheUUID`, 캐시 버전이 현재 기기와 같고, 백업의 제품·보드 정보가 커널에서 확인한 실제 하드웨어와 일치해야 합니다. 제품·보드·CPU와 원래 규제 모델 번호만 복원하므로 현재 AI, Siri, 지역 등 나머지 설정은 유지됩니다. YumEdit의 지역 활성화 방식처럼 규제 모델을 미국 모델로 바꾸지는 않습니다. 백업이 없거나 호환되지 않거나 이미 위장된 백업이면 복구할 수 없습니다. 원래 하드웨어 값을 추측해서 채워 넣지 않습니다.

현재 복구를 지원하는 기기는 iPhone 11부터 iPhone 15/15 Plus까지이며, 2·3세대 iPhone SE도 포함됩니다. 실제 기기 모델에 해당하는 칩 정보와 백업의 원래 CPU가 일치하는지 확인합니다. 그 밖의 모델은 칩을 추측하지 않고 복구를 거부합니다. 저장 전에는 백업을 만들고, 저장 후에는 전체 결과를 검증합니다. **기기를 완전히 재시동한 뒤 Face ID, 받아쓰기, Apple Intelligence가 작동하는지 확인하세요.** 이 기능은 하드웨어 정보 위장으로 생긴 문제를 복구하기 위한 것으로, 모든 Face ID 문제를 해결하지는 못합니다. 실제 복구 여부는 문제가 생긴 기기에서 확인해야 합니다.

## 호환성

**iOS / iPadOS 27.x**를 지원합니다. **iOS / iPadOS 26.x에서는 기기의 MobileGestalt에 직접 접근하는 기능을 지원하지 않습니다.** [worse_query](https://github.com/forcequitOS/worse_query)를 사용하며, SystemGroup 접근에는 iOS 27이 필요합니다. 사용 가능한 기능은 기기와 OS에 따라 다릅니다. 로컬 plist 파일도 편집할 수 있습니다.

앱을 서명하려면 App Group을 하나 이상 사용할 수 있는 인증서와 프로비저닝 프로파일이 필요합니다. 앱과 내장 공유 확장 프로그램이 **같은 App Group을 하나 이상 사용하도록** 서명하고, 재서명할 때도 확장 프로그램을 유지하세요. 앱과 확장 프로그램은 실행할 때 서명에 실제로 포함된 App Group을 확인합니다. 배포되는 IPA는 개발자 인증서 대신 ad-hoc 방식으로 서명되어 있습니다. SideStore와 AltStore가 재서명할 때 인식할 수 있도록 해당 권한이 포함되어 있습니다.

## 다운로드

[릴리스](https://github.com/huamidev/GestaltX/releases/latest)에서 IPA를 다운로드하세요.
일부 사용자는 iOS 27의 Safari에서 파일이 끝까지 다운로드되지 않는 문제를 겪었다고 합니다. 파일이 손상되었다고 나오거나 압축이 풀리지 않으면 다시 다운로드하세요. 여러 번 시도해야 할 수도 있습니다. 계속 문제가 생기면 다른 브라우저를 사용해 보세요. 원인은 아직 확인되지 않았습니다.

## plist 가져오기

파일 앱이나 다른 앱에서 MobileGestalt plist를 선택하고 **공유 → GestaltX**를 누르세요. 공유 확장 프로그램이 파일을 읽어 공통 App Group을 통해 앱에 전달합니다. 앱이 자동으로 열리지 않으면 직접 GestaltX로 돌아가세요.

앱은 파일이 이 기기에서 나온 것인지 확인한 뒤 가져올지 묻습니다. GestaltX에서 내보낸 파일에 담긴 기기 검증 정보를 확인하거나, 이 기기에서 직접 얻은 고유 식별자 2개 이상과 대조합니다. 확인할 수 없는 파일은 가져올 수 없습니다. 이전에 가져온 파일을 기기 식별 기준으로 삼지는 않습니다.

원본 plist 중에는 고유한 기기 식별자가 없는 파일도 있습니다. 이 경우 먼저 해당 기기의 GestaltX에서 사본을 내보내세요. 검증 키는 이 기기에서만 쓸 수 있는 키체인에 보관되며, 내보낸 파일에는 포함되지 않습니다.

공유된 파일은 앱을 실행하거나 다시 앱으로 돌아왔을 때 확인합니다. 편집 중인 내용은 저장하거나 취소할 때까지 유지됩니다. 가져오기를 승인한 파일은 로컬 문서로 열립니다. **MG Control**에서는 자료형을 지정해 키와 값을 추가하거나, 편집·이름 변경·삭제할 수 있습니다.

검증된 파일을 기기에 복원하려면 **가져온 plist 복원**을 사용하세요. 시스템 캐시 구조가 일치해야 하며, 복원 여부를 한 번 더 확인합니다. 현재 파일을 백업한 뒤 복원하고 저장 결과를 검증합니다. 완료 후 기기를 재시동하세요.

## 지원 언어

GestaltX는 iOS 언어 설정을 따릅니다. 기본 언어는 영어이며, 설정한 언어를 지원하지 않으면 영어로 표시됩니다. 페르시아어는 오른쪽에서 왼쪽으로 읽는 화면 배치를 지원합니다.

| 언어 | 로케일 |
| --- | --- |
| English — 영어 | `en` |
| 简体中文 — 중국어 간체 | `zh-Hans` |
| 繁體中文（台灣）— 중국어 번체(대만) | `zh-Hant-TW` |
| 繁體中文（香港）— 중국어 번체(홍콩) | `zh-Hant-HK` |
| Tiếng Việt — 베트남어 | `vi` |
| Русский — 러시아어 | `ru` |
| فارسی — 페르시아어 | `fa` |
| 한국어 | `ko` |
| Español — 스페인어 | `es` |
| 日本語 — 일본어 | `ja` |

## 감사의 말

- [forcequitOS / Taj C — worse_query](https://github.com/forcequitOS/worse_query)
- [neonmodder123](https://github.com/neonmodder123)
- [skadz108](https://github.com/skadz108)
- [rooootdev — NeoSpring](https://github.com/rooootdev/neospring)
- [Nouvborne — Ketamine](https://github.com/Nouvborne/Ketamine)
- [PoomSmart — MGKeys](https://github.com/PoomSmart/MGKeys)
- [leminlimez — Nugget](https://github.com/leminlimez/Nugget)
- [rooootdev — mond](https://github.com/rooootdev/mond)
- [frs0n — GestaltEdit](https://github.com/frs0n/GestaltEdit)

## 면책 조항

보안 연구와 교육 목적으로만 사용하세요. 본인 소유이거나 관리 권한이 있는 기기에서만 사용하세요.

수정하기 전에 데이터를 백업하세요. MobileGestalt를 수정하면 시스템이 불안정해지거나 기기를 복원해야 할 수 있습니다. 변경 사항을 적용한 결과와 그에 따른 위험은 사용자 본인의 책임입니다.

## 라이선스

[GNU GPL v3](LICENSE) · Copyright © 2026 huamidev.

## 스타 기록

<a href="https://www.star-history.com/#huamidev/GestaltX&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=huamidev/GestaltX&amp;type=Date&amp;theme=dark" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=huamidev/GestaltX&amp;type=Date" />
    <img width="480" alt="GestaltX 스타 기록" src="https://api.star-history.com/svg?repos=huamidev/GestaltX&amp;type=Date" />
  </picture>
</a>
