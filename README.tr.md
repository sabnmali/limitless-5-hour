# No 5-Hour Limit

Resmî Claude Code ve Codex CLI araçlarına zamanlanmış, küçük mesajlar gönderir.
[English](README.md) · [Güvenlik](SECURITY.md)

## Gerçekte ne yapar?

Her servisin son başarılı gönderiminden en az **301 dakika** geçince `ok`
gönderir. Birbirinden bağımsız iki gönderim zamanı tutar. Kullanılmayan bir
oturumun sayacını başlatabilir; açık pencereyi sıfırlamaz, kota artırmaz ve
çalışmaya döndüğünde kullanım hakkın olacağını garanti etmez. Her mesaj,
haftalık kota dahil kullanım hakkından harcar.

Projenin adı sınırsız kullanım sözü değildir. Script, sağlayıcının gerçek
sayaçlarını değil **kendi başarılı gönderim zamanlarını** takip eder. Başarılı
bir cevap yalnızca mesajın işlendiğini kanıtlar; yeni pencere açıldığını değil.

## Hangi uygulama ve modelleri kapsar?

| Alan | Kapsam |
|---|---|
| Claude / Claude Code / Cowork | Uygun aboneliklerde Claude Code kullanımı ortak kotaya dahildir. Model, özellik, haftalık ve aylık ek limitler devam eder. |
| Codex | ChatGPT abonelik girişiyle resmî Codex CLI üzerinden mesaj gönderir. |
| Normal ChatGPT sohbetleri | **Desteklenmiyor.** Sohbet kullanım kuralları Work/Codex'ten ayrıdır. Codex mesajı bütün ChatGPT modellerinin sayaçlarını başlatmaz. |
| Google Antigravity | **Henüz desteklenmiyor.** Antigravity CLI'ın (`agy -p`) arayüzsüz modu var ama girişi işletim sisteminin anahtar deposunda tutuluyor; bulut yolu yok ve Google, CLI kullanımının IDE'nin kota penceresini başlatıp başlatmadığını belgelemiyor. |
| Başka AI araçları | Genel bir destek yoktur; resmî entegrasyon ve gerçek kota kuralları ayrıca doğrulanmalıdır. |

Eylül 2026'da kontrol edilen kaynaklar:
[OpenAI: sohbet ve Work/Codex ayrımı](https://help.openai.com/en/articles/20001354),
[Claude Code Pro/Max](https://support.claude.com/en/articles/11145838-using-claude-code-with-your-pro-or-max-plan),
[Claude kullanım limitleri](https://support.claude.com/en/articles/9797557-usage-limit-best-practices).
Ortak kota, tek mesajın modele özel bütün sayaçları başlattığı anlamına gelmez.

## Nerede çalışmalı?

Cihazlar dahil **her servis/hesap için tek zamanlayıcı** kullan. Claude bulutta,
Codex yerelde çalışabilir. Aynı servisi iki bağımsız zamanlayıcıda açmak gereksiz
kota tüketir.

- **Yerel:** Windows Görev Zamanlayıcı, macOS launchd veya Linux cron.
  Mevcut CLI girişini kullanır. Bilgisayar açık, uyanık ve çevrimiçi olmalıdır.
  Windows görevi ayrıca açıkça etkinleştirilmelidir; oturum ve priz bağlantısı
  gerektirir. Bilgisayarı uyandırmaz. Bazı CLI işlemleri kısa konsol parlaması
  oluşturabilir; laptopta rahatsızlık varsa yerel otomasyonu kapat.
- **Bulut:** GitHub Actions. Bilgisayar kapalıyken de çalışır. Her 30 dakikada
  kontrol eder; GitHub çalışmaları geciktirebilir veya atlayabilir. Dakikası
  dakikasına zamanlama garantisi yoktur. Abonelik erişim bilgisi depo secret'ı olur.

**Bulut kimlik bilgileri özel bir dağıtım deposunda tutulmalıdır.** Bu public
depo yalnızca kaynak şablonudur. [OpenAI'ın CI/CD giriş rehberi](https://learn.chatgpt.com/docs/auth/ci-cd-auth),
ChatGPT yönetimli `auth.json` kullanımını güvenilen özel otomasyonla sınırlar ve public/açık kaynak depolarda
kullanılmamasını söyler. Bu şablondan private depo oluştur; abonelik anahtarını
public forka koyma.

**Codex için yerel kurulum tercih edilir.** Yenileme anahtarları değişir.
Masaüstündeki aynı oturumu geçici bir bulut çalıştırıcısına kopyalamak GitHub'daki
anahtarı eskitebilir ve masaüstü girişiyle çakışabilir. Bulut Codex desteği
anahtar bakımı gerektirir; kalıcı, bakım gerektirmeyen giriş değildir. Bu proje
ayrı bir giriş ve yalnızca bu depoya erişen secret güncelleme anahtarıyla
yenilenen Codex girişini GitHub'a geri kaydeder.
[Netlify kurulumu ve gerekli yetkiler](NETLIFY.md), GitHub cron geciktiğinde
otuz dakikada bir çalışan bağımsız tetikleyicinin kurulumunu açıklar.

## Yerel kurulum

Resmî CLI araçlarını ayrıca kur ve aboneliğinle giriş yap:

```sh
claude auth login
npm install -g @openai/codex
codex login  # isteğe bağlı; API anahtarı değil ChatGPT girişi
```

Test edilen bulut sürümleri: Claude Code **2.1.276**, Codex **0.155.0**. Eski
sürümler kullanılan yalıtım seçeneklerini desteklemeyebilir. Çalıştırmak için
Python gerekmez; Python yalnızca geliştirme testlerinde kullanılır.

```sh
git clone https://github.com/sabnmali/limitless-5-hour.git
cd limitless-5-hour
```

`config.example.env` dosyasını `config.env` olarak kopyala; kurmadan önce
servisleri seç. Claude zaten buluttaysa yalnızca Codex için:

```ini
CLAUDE_ENABLED=false
CODEX_ENABLED=true
```

Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install\install-windows.ps1 -EnableLocal
```

macOS / Linux:

```sh
./install/install-unix.sh
```

Kurulum zamanlayıcıyı oluşturur, CLI yollarını kaydeder ve Claude becerisini
kurar. Windows görevi başlatıp sonucunu da kontrol eder. Gönderim zamanı
henüz gelmemişse başarılı bir görev, CLI bağlantısını kanıtlamaz. Unix'te
scripti bir kez çalıştırarak sırası gelen gönderimi kontrol et. CLI bulunamıyorsa
`*_BIN` alanına tam yolunu yaz. Windows Claude kurulum/giriş yardımcısı:
`install/setup-cli-windows.ps1`.

## Bulut kurulumu

Bu public şablondan **private** bir dağıtım deposu oluştur. Public fork kullanma:

```sh
gh repo create my-limitless-5-hour --private --template sabnmali/limitless-5-hour --clone
cd my-limitless-5-hour
```

Aşağıdaki kurulumu **kendi normal terminalinde** çalıştır. Claude girişi ve
token yapıştırılması insan gerektirir; asistan depoyu hazırlayabilir fakat basılan
Claude token'ını yakalamamalıdır.

```powershell
powershell -ExecutionPolicy Bypass -File install\setup-cloud-windows.ps1
```

```sh
./install/setup-cloud.sh
```

Kaynak şablonunda iki bulut sağlayıcısı da kapalıdır. Kurulum Claude secret'ını
kaydeder, `L5H_CLAUDE_ENABLED=true` değişkenini ayarlar, workflow'u etkinleştirir
ve zaman kontrolü başlatır. İsteğe bağlı bulut Codex için Windows'ta `-Codex`,
Unix'te `--codex` ayrı ChatGPT yönetimli auth.json'ı doğrulayıp yükler ve
`L5H_CODEX_ENABLED=true` ayarlar. Secret ve repository değişkenleri şablondan
aktarılmaz. Private dağıtımdaki kod değişikliklerini çalıştırmadan önce incele.

İş akışı yalnızca varsayılan dalda çalışır. Sağlayıcı işleri ayrı ve salt
okunurdur; yalnız temiz durum-kayıt işi `contents: write` alır. Action commit'leri ve CLI sürümleri sabitlenmiştir. Güncellemeleri
incelemeden değiştirme. GitHub zamanlanmış çalışmaları durdurabilir; Actions
sayfasını kontrol et. Private depo dakikaları ve ek ücretler GitHub planına ve
çalışma sürelerine bağlıdır; sabit aylık maliyet garantisi yoktur.

## Ayarlar

`config.env` yereldir ve Git'e eklenmez. `cloud.env` public kaynak şablonudur ve
iki bulut sağlayıcısını da kapalı tutar. İkisi de yalnızca KEY=VALUE verisidir;
bilinmeyen anahtarlar dikkate alınmaz. Private dağıtımdaki
`L5H_CLAUDE_ENABLED` ve `L5H_CODEX_ENABLED` değişkenleri ilgili anahtarı açar.

| Anahtar | Varsayılan | Anlamı |
|---|---|---|
| INTERVAL_MINUTES | 301 | Başarılı gönderimden sonraki en az dakika; 300–525600 aralığına sınırlandırılır. |
| CLAUDE_ENABLED | false | Public şablon varsayılanı; private kurulum repository değişkeniyle açar. |
| CLAUDE_MODEL | haiku | Claude model adı veya kimliği. |
| CLAUDE_PROMPT | ok | Gönderilecek kısa metin. |
| CLAUDE_BIN | boş | CLI tam yolu; boşsa bilinen konumlar aranır. |
| CODEX_ENABLED | false | Codex'i açar. |
| CODEX_MODEL | boş | CLI'ın yerleşik varsayılanı. Kullanıcı config'i bilerek yüklenmez. Planında bulunan hafif bir model seçebilirsin. |
| CODEX_PROMPT | ok | Codex'e gönderilecek kısa metin. |
| CODEX_BIN | boş | CLI tam yolu. |
| CODEX_REASONING_EFFORT | low | Seçilen modelin desteklediği düşünme seviyesi. |
| LOG_RETENTION_DAYS | 30 | Eski aylık keepalive kayıtlarını temizler; 0 temizliği kapatır. |
| QUIET_HOURS | boş | Yerel saate göre HH:MM-HH:MM. GitHub çalıştırıcısı UTC kullanır. |

Claude güvenli/kısıtlı modda, yerleşik araçlar ve MCP kapalı çalışır.
Codex salt okunur ortamda kullanıcı ayarlarını, kurallarını ve proje belgelerini
yüklemeden çalışır. Codex'in yerleşik araçları hâlâ vardır; güvenmediğin metni
prompt olarak kullanma. Yönetici politikaları geçerli olabilir. Her CLI çağrısı
yaklaşık 120 saniyeyle sınırlıdır. Bir servisin hatası diğerinin başarısını silmez.

## Durum ve kontrol

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File bin\keepalive.ps1 -Status
powershell -NoProfile -ExecutionPolicy Bypass -File bin\keepalive.ps1 -DryRun
# Yalnızca hemen gerçek mesaj gönderilmesi isteniyorsa:
powershell -NoProfile -ExecutionPolicy Bypass -File bin\keepalive.ps1 -Force
```

```sh
./bin/keepalive.sh --status
./bin/keepalive.sh --dry-run
./bin/keepalive.sh --force
L5H_STATE_FILE=state/cloud-state.env ./bin/keepalive.sh --config cloud.env --status
gh run list --workflow keepalive.yml -L 5
```

Tahmini bitiş = son gönderim + 5 saat. **Sağlayıcıdan alınmış sıfırlanma saati
değildir.** Gerçek sayaç için servisin Kullanım sayfasına bak. `--force` aralığı
ve sessiz saatleri yok sayar; açık pencereyi sıfırlamaz. Bash `--due` gönderim
zamanı geldiyse 0, iş yoksa 3 döner. `--enabled` açık servisleri listeler.
Normal çalışmada servis veya durum yazma hatası 1 döndürür.

Servis "kullanım limitine ulaşıldı" derse bu hata sayılmaz: çalışma 0 ile
biter, uyarı yazar ve bir sonraki deneme zamanını kaydeder. Bu zaman servisin
söylediği sıfırlanma süresidir (Codex "try again in …" der), yoksa bir saattir;
30 dakika ile 7 gün arasında tutulur. `--status` bunu gösterir, `--force` yok
sayar. Bulutta başarısız çalışma yerine uyarı notu olarak görünür; kota bitmişken
GitHub her yarım saatte hata maili atmaz.

## Sorun giderme ve kaldırma

PowerShell pencereleri açılıyorsa veya laptopun uykusu etkileniyorsa:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install\disable-local-windows.ps1
```

Bu işlem görevi durdurur, devre dışı bırakır ve uyandırma iznini kaldırır.
Ayarları ve hesap girişini silmez. Kurucu `-EnableLocal` verilmeden değişiklik
yapmaz; CLI kurulum yardımcısı da görevi yeniden etkinleştirmez. Ekran/HDR
sorununun nedeni ayrıca doğrulanmalıdır; bu script ekran ayarlarını değiştirmez.

Yeşil GitHub çalışması yalnızca “henüz zamanı gelmedi” anlamına gelebilir.
Gerçek mesajı **Ping** adımı ve kayıtlı zamanlarla kontrol et. Güvenlik için ham
CLI hata çıktıları yayımlanmaz. `claude auth status`, `codex login status`, CLI
sürümleri ve model erişimini kontrol et. Başarısız gönderim bir sonraki
zamanlayıcı turunda yeniden denenir.

```powershell
powershell -ExecutionPolicy Bypass -File install\uninstall-windows.ps1
```

```sh
./install/uninstall-unix.sh
# Bulut:
gh workflow disable keepalive.yml
```

Yerel kaldırma ayarları, kayıtları ve CLI girişini korur. İş akışını kapatmak
anahtarı iptal etmez. İptal işlemleri [SECURITY.md](SECURITY.md) içindedir.

## Geliştirme

```sh
python -m unittest discover -s tests -v
```

Testler sahte CLI ve geçici klasörlerle çalışır, gerçek AI hesabı kullanmaz.
Test iş akışı Windows, Linux ve macOS'u kapsar. Scriptler `bin/`, kurulumlar
`install/` içindedir. `AGENTS.md` ve `CLAUDE.md` birebir aynı tutulur. Yerel
kayıtlar, kimlik bilgileri ve talimat yedekleri Git'e eklenmez.

MIT — [LICENSE](LICENSE). Anthropic veya OpenAI ile bağlantılı değildir.
