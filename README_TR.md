<p align="center">
  <img src="GestaltX/Assets.xcassets/AppIcon.appiconset/AppIcon.png" alt="GestaltX" width="112" height="112">
</p>

<h1 align="center">GestaltX</h1>

[![Version](https://img.shields.io/badge/version-1.0.6-blue)](https://github.com/huamidev/GestaltX)
[![Platform](https://img.shields.io/badge/iOS-27.x-black?logo=apple)](#uyumluluk)
[![SwiftUI](https://img.shields.io/badge/Swift-SwiftUI-orange?logo=swift)](https://github.com/huamidev/GestaltX)
[![License](https://img.shields.io/badge/license-GPLv3-blue)](LICENSE)

[English](README.md) · [简体中文](README_ZH-CN.md) · [日本語](README_JA.md) · [한국어](README_KO.md) · [Türkçe](README_TR.md)

iPhone ve iPad için bir MobileGestalt düzenleyicisi. [huamidev](https://github.com/huamidev) tarafından geliştirilmiştir.

## Özellikler

| Kategori | Ön ayarlar ve araçlar |
| --- | --- |
| Ekran | Dynamic Island yeteneği ve düzeni, Always-On Display, AOD Canlılığı, yüksek parlaklıklı AOD, AOD flipbook, HDR fotoğraf görüntüleme, duvar kağıdı paralaksı, Liquid Glass düşük güçlü işleme, deneysel PWM ve DisplayPort bayrakları |
| Cihaz | Model adı, açılış/kapanış tonu, şarj sınırı, dokunarak uyandırma, Kamera Denetimi ayarları, Eylem Düğmesi ayarları, Çarpışma SOS, Ses Karışımı, Uzamsal FaceTime sesi |
| iPad | Apple Pencil ayarları, Stage Manager yeteneği, iPad uygulama uyumluluğu |
| Zekâ | Bağımsız bölge kodu seçenekleri, Apple Intelligence yetenek bayrağı, cihaz üzerinde Siri, Ses Zekâsı, Kişisel Çevirmen, Fotoğraflar Temizleme, El Yazısı Sentezi, sürekli dinleyen Hey Siri ve Çin anakarası cihazlarında etkinleştirme denemeleri için satış bölgesi seçenekleri |
| Gelişmiş | Apple dahili özellik bayrakları, açık etkinleştirme onayıyla sistem genelinde InternalBuild bayrağı, dahili ayarlar paketi, Security Research Device bayrağı |
| Alan düzenleyici | `CacheExtra` alanlarını okuma, arama, ekleme, düzenleme ve kaldırma; yerel plist içe/dışa aktarma; Dize, Tam Sayı, Ondalık Sayı, Boole, Veri, Tarih, Dizi ve Sözlük değerleri |
| Değişiklikler | Otomatik okuma ve elle yeniden okuma, uygulanmadan önce önce/sonra incelemesi, doğrulanmış yazmalar, ön ayar başına geri yükleme |
| Yedekler | Cihaz düzenlemesinden önce otomatik ilk yedek, her yazmadan önce yedek, özgün değer kayıtları; açma, dışa aktarma, geri yükleme ve silme |
| Günlükler ve respring | Fiili exploit aşaması günlükleri ve elle NeoSpring respring |

Genellikle AI etkinleştirmeyi denemek için bölge kodunu değiştirmek yeterlidir; Satış Bölgesi'ni değiştirmeye gerek yoktur. Bölge Kodu için Amerika Birleşik Devletleri seçmek `RegionCode`'u `LL` yapar ve satış bölgesi son ekini korur. Ayrıca Çin (Anakara), Hong Kong, Tayvan, Japonya veya Birleşik Krallık seçebilirsiniz. Satış Bölgesi ve Bölge Kodu birlikte uygulanabilir: satış son ekini Satış Bölgesi, kodu ise Bölge Kodu izler.

*Daha önce Satış Bölgesi'ni değiştirdiyseniz, cihazınızın özgün satış bölgesini geri yükleyin ve önce onu uygulayın.*

Bir ön ayarı devre dışı bırakmak veya Geri Al düğmesini kullanmak, kaydedilen özgün değerleri ve türleri geri yükler. Baştan yok olan anahtarlar kaldırılır. Daha eski bir değişikliğin özgün kaydı yoksa, Eklenen Alanları Kaldır'ı yalnızca bu alanların eklendiğini bildiğinizde kullanın.

Ön ayarlar yetenek bayraklarını değiştirir; fiili etkiler cihaza ve OS'a bağlıdır. Çin anakarası cihazları, etkinleştirme denemesi için Apple Intelligence ve bölge seçeneklerini kullanabilir; kullanılabilirlik ayrıca modele, OS sürümüne ve Apple hizmetlerine bağlıdır.

### Apple Intelligence, Face ID ve dikte

[YumEdit 1.2.1 yaklaşımı](https://github.com/H4CNPE/YumEdit/tree/v1.2.1), ürün, kart ve CPU'yu taklit etmekten kaçınır. Zekâ bölümünde **Apple Intelligence Yeteneği**, üretken model bayrağını `1` yapar; ayrı bir ön ayar olan **Siri AI Modu** ise `SiriMode`'u `2` yapar. İkisi de donanım kimliğini veya cihaza özgü Cihazda Siri yeteneğini değiştirmez. Bunlar deneysel bayraklardır; kaynak indirmelerinin veya çalışan bir Apple Intelligence'ın garantisi değildir. YumEdit bu etkinleştirme yaklaşımını daha sonra deneysel iki aşamalı bir iş akışıyla değiştirdi; GestaltX geçici donanım taklidini uygulamaz.

Daha önceki bir donanım taklidi Face ID'yi veya dikteyi bozduysa, **Yedekler → Donanım Kimliğini Geri Yükle** bölümünden özgün bir cihaz yedeği seçin. Alternatif olarak, doğrulanmış özgün bir plist'i içe aktarın ve **Zekâ → Donanım Kimliğini Geri Yükle** yolunu kullanın. Önce bekleyen değişiklikleri kaydedin veya atın. Kurtarma, aynı `CacheData`, `CacheUUID` ve önbellek sürümüne sahip, doğrulanmış, aynı cihazdan bir yedek gerektirir; bu yedeğin ürün ve kart bilgisi çekirdeğin bildirdiği donanımla eşleşmelidir. Yalnızca ürün, kart, CPU ve özgün düzenleyici model numarasını geri yükler; geçerli AI, Siri, bölge ve ilgisiz ayarları korur. YumEdit'in bölge etkinleştirmesinin aksine kurtarma, ABD düzenleyici modeli yerine koymaz. Eksik, uyumsuz veya zaten taklit edilmiş yedekler reddedilir; özgün donanım değerleri asla tahmin edilmez.

Kurtarma şu anda iPhone 11'den iPhone 15/15 Plus'a kadar (ikinci ve üçüncü nesil SE dahil) tanır; fiziksel ürüne karşılık gelen özgün CPU'yu bilinen çiple karşılaştırır. Diğer ürünler çipleri tahmin edilmek yerine reddedilir. Yazmadan önce bir yedek oluşturulur ve tam sonuç doğrulanır. **Cihazı tam olarak yeniden başlatın, ardından Face ID, dikte ve Apple Intelligence'ı test edin.** Bu kurtarma, donanım taklit kaynaklı zararları ele alır; her olası Face ID arızasını değil. Cihaz düzeyindeki davranış yine de etkilenen donanımda test gerektirir.

## Uyumluluk

**iOS / iPadOS 27.x** desteklenir. **Cihaz üzerinde MobileGestalt erişimi için iOS / iPadOS 26.x desteklenmez.** [worse_query](https://github.com/forcequitOS/worse_query) ile güçlendirilmiştir. SystemGroup erişimi iOS 27 gerektirir; kullanılabilir özellikler cihaza ve OS'a bağlıdır. Yerel plist düzenlemesi de desteklenir.

İmzalama, en az bir kullanılabilir App Group içeren bir sertifika ve provisioning profili gerektirir. Uygulamayı ve gömülü paylaşılan uzantısını en az bir **ortak App Group** ile imzalayın ve yeniden imzalarken uzantıyı koruyun. Her iki işlem de çalışma zamanında fiilen imzalanan App Group'larını saptar. Dağıtılan IPA'lar, SideStore ve AltStore'un yeniden imzalarken bunları algılayabilmesi için bu yetenekleri gömülü olarak taşıyan geçici (ad-hoc) imzalarla imzalanır; geliştirici sertifikasıyla imzalanmazlar.

## İndirme

IPA'yı [Releases](https://github.com/huamidev/GestaltX/releases/latest) sayfasından indirin. Bazı kullanıcılar iOS 27'de Safari ile eksik indirmeler bildiriyor. Dosya hasarlı bildirilirse veya açılamazsa yeniden indirin; birkaç deneme gerekebilir. Sorun sürerse başka bir tarayıcı deneyin. Nedeni doğrulanmadı.

## Plist içe aktarma

Files'da veya başka bir uygulamada bir MobileGestalt plist'i seçin, **Paylaş**'a dokunun ve **GestaltX**'i seçin. Paylaşılan uzantı, sağlanan dosyayı okur ve onu ortak App Group üzerinden uygulamaya iletir. Otomatik açılmazsa GestaltX'e geri dönün. Uygulama, bir GestaltX dışa aktarımından gelen cihaza bağlı kanıtı veya bu cihazdan alınmış en az iki benzersiz tanımlayıcıyı denetler, sonra içe aktarmayı onaylamanızı ister. Doğrulanamayan dosyalar reddedilir. Daha önce içe aktarılan dosyalar asla cihaz kimliği referansı olarak kullanılmaz.

Bazı özgün plist'ler benzersiz cihaz tanımlayıcısı içermez. Önce bu cihazda GestaltX'ten bir kopya dışa aktarın: doğrulama anahtarı yalnızca cihaza özel Keychain'de kalır ve dosyaya asla dahil edilmez.

Paylaşılan dosyalar başlangıçta ve ön plana dönüşte denetlenir. Kaydedene veya atana kadar bekleyen düzenlemeler korunur. Onaylanan içe aktarmalar yerel belge olarak açılır. **MG Control**, türü belirtilmiş anahtar ve değer ekleme, düzenleme, yeniden adlandırma ve silmeyi destekler. Doğrulanmış bir dosyayı bu cihaza geri yüklemek için **İçe Aktarılan Plist'i Geri Yükle** yolunu kullanın; geri yükleme, eşleşen bir sistem önbelleği düzeni ve ek bir onay gerektirir, geçerli dosyanın yedeğini alır ve yazmayı doğrular. Sonrasında cihazı yeniden başlatın.

## Dil desteği

GestaltX, iOS dil ayarlarınızı izler; varsayılan ve yedek dil İngilizce'dir. Farsça, sağdan sola düzen desteği içerir.

| Dil | Yerel ayar |
| --- | --- |
| English | `en` |
| 简体中文 — Basitleştirilmiş Çince | `zh-Hans` |
| 繁體中文（台灣）— Geleneksel Çince (Tayvan) | `zh-Hant-TW` |
| 繁體中文（香港）— Geleneksel Çince (Hong Kong) | `zh-Hant-HK` |
| Tiếng Việt — Vietnamca | `vi` |
| Русский — Rusça | `ru` |
| فارسی — Farsça | `fa` |
| 한국어 — Korece | `ko` |
| Español — İspanyolca | `es` |
| 日本語 — Japonca | `ja` |
| Türkçe | `tr` |

## Teşekkürler

- [forcequitOS / Taj C — worse_query](https://github.com/forcequitOS/worse_query)
- [neonmodder123](https://github.com/neonmodder123)
- [skadz108](https://github.com/skadz108)
- [rooootdev — NeoSpring](https://github.com/rooootdev/neospring)
- [Nouvborne — Ketamine](https://github.com/Nouvborne/Ketamine)
- [PoomSmart — MGKeys](https://github.com/PoomSmart/MGKeys)
- [leminlimez — Nugget](https://github.com/leminlimez/Nugget)
- [rooootdev — mond](https://github.com/rooootdev/mond)
- [frs0n — GestaltEdit](https://github.com/frs0n/GestaltEdit)

## Sorumluluk Reddi

Yalnızca güvenlik araştırması ve eğitim amaçlıdır. Yalnızca sahip olduğunuz veya yönetmeye yetkili olduğunuz cihazlarda kullanın.

Değişiklik yapmadan önce verilerinizi yedekleyin. MobileGestalt'ı değiştirmek sistem kararsızlığına yol açabilir veya bir cihaz geri yüklemesi gerektirebilir. Uyguladığınız değişikliklerin ve bunlara bağlı risklerin sorumluluğu size aittir.

## Lisans

[GNU GPL v3](LICENSE) · Telif Hakkı © 2026 huamidev.

## Star History

<a href="https://www.star-history.com/#huamidev/GestaltX&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=huamidev/GestaltX&amp;type=Date&amp;theme=dark" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=huamidev/GestaltX&amp;type=Date" />
    <img width="480" alt="GestaltX Star History" src="https://api.star-history.com/svg?repos=huamidev/GestaltX&amp;type=Date" />
  </picture>
</a>
