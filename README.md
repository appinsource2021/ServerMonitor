# Server Monitor

Dedicated sunucuları iPhone'dan izlemek için bir uygulama: CPU, RAM, disk, Docker container'ları, loglar, systemd servisleri, alarmlar ve ekip erişimi.

> Designed & developed by **appinsource** · Süleyman Topaloğlu

---

## İçindekiler

1. [Nasıl çalışır](#1-nasıl-çalışır)
2. [Proje klasörü](#2-proje-klasörü)
3. [Uygulamayı iPhone'a kurmak](#3-uygulamayı-iphonea-kurmak)
4. [Sunucu eklemek](#4-sunucu-eklemek)
5. [iPhone key: şifresiz giriş](#5-iphone-key-şifresiz-giriş)
6. [Taslaklar: yarım kalan kurulumlar](#6-taslaklar-yarım-kalan-kurulumlar)
7. [Uygulamayı kullanmak](#7-uygulamayı-kullanmak)
8. [Alarmlar ve push bildirimleri](#8-alarmlar-ve-push-bildirimleri)
9. [Ekip erişimi (Team) ve relay](#9-ekip-erişimi-team-ve-relay)
10. [Sorun giderme](#10-sorun-giderme)
11. [Agent'ı sunucuda yönetmek](#11-agentı-sunucuda-yönetmek)
12. [Güvenlik](#12-güvenlik)
13. [Planlar: Free, Trial, Pro](#13-planlar-free-trial-pro)
14. [Marka yazımı: appinsource](#14-marka-yazımı-appinsource)
15. [Geliştirme](#15-geliştirme)

---

## 1. Nasıl çalışır

```
Admin (sen)                         Ekip üyeleri
iPhone ──SSH (22)──▶ sunucu          iPhone ──HTTPS──▶ relay ◀──HTTPS (dışarı doğru)── sunucu
                      │                                                                  │
                      └─ srvmon-agent (sadece yerel socket, port açmaz) ◀────────────────┘
```

- Her sunucuda **srvmon-agent** adında küçük bir program çalışır (Go ile yazılmış, tek dosya). Agent metrikleri `/proc` üzerinden, container bilgisini Docker'dan, servisleri systemd'den okur.
- Agent internete **hiç port açmaz**. Sadece `/run/srvmon/agent.sock` dosyası üzerinden dinler ve bu dosyaya yalnızca root erişebilir.
- **Admin olarak sen** sunucuya SSH ile bağlanırsın. Uygulama her istekte SSH üzerinden `srvmon-agent api …` komutunu çalıştırır.
- **Ekip üyeleri** SSH bilgisi almaz. Bir **relay** sunucusu üzerinden bağlanırlar. Agent relay'e kendisi, içeriden dışarı doğru bağlanır, bu yüzden sunucularda port açmak gerekmez.
- **Agent'ı ayrıca kurman gerekmez.** Uygulama, sunucu eklerken agent'ı sunucuya kendisi yükler ve kurar.

## 2. Proje klasörü

| Klasör | İçerik |
|---|---|
| `ios/` | SwiftUI uygulaması (Xcode projesi: `ios/ServerMonitor.xcodeproj`) |
| `agent/` | Sunucuya kurulan `srvmon-agent` (Go) |
| `relay/` | Ekip erişimi için relay sunucusu (Go + Docker) |
| `e2e/` | Relay ve agent'ı birlikte deneyen uçtan uca test |
| `official/` | Tanıtım sitesi (İngilizce, statik; `monitor.appinsource.eu` kökünde yayınlanacak). Yayınlama notları `official/README.md` |

## 3. Uygulamayı iPhone'a kurmak

**Gerekenler:** Xcode yüklü bir Mac, kabloyla bağlı bir iPhone, Xcode'da oturum açılmış bir Apple ID.

1. `ios/ServerMonitor.xcodeproj` dosyasını Xcode ile aç.
2. Soldan **ServerMonitor** projesini, ardından **Signing & Capabilities** sekmesini seç ve **Team** olarak kendi hesabını seç.
3. iPhone'da şunlar hazır olmalı:
   - Kilidi açık olsun ve "Bu bilgisayara güven" onaylanmış olsun.
   - **Ayarlar → Gizlilik ve Güvenlik → Geliştirici Modu** açık olsun. Açınca telefon yeniden başlar.
4. Xcode'un üst çubuğundan iPhone'u seç ve **▶ Run**'a bas.
5. İlk kurulumda uygulama açılmaz ve "Developer App Certificate is not trusted" hatası çıkar. iPhone'da **Ayarlar → Genel → VPN ve Cihaz Yönetimi**'ne gir, kendi Apple ID'ne dokun ve **Güven**'e bas.
6. Uygulamayı aç. Face ID ve bildirim izni sorulur.

**Kişisel (ücretsiz) Apple hesabıyla kurduysan:**
- Uygulamanın imzası **7 gün** geçerli. Süre dolunca Xcode'dan tekrar **Run**'a bas.
- **Push bildirimleri çalışmaz**, çünkü ücretsiz hesap push yetkisi vermiyor. Bkz. [Bölüm 8](#8-alarmlar-ve-push-bildirimleri).

## 4. Sunucu eklemek

Uygulamada **Servers → +**'ya bas. Sonra:

1. **Bağlantı bilgilerini gir:**
   - **Name:** Listede görünecek isim, örneğin `Romon Prod`.
   - **Host:** IP adresi veya alan adı.
   - **Port:** Genelde 22.
   - **User:** `root` (agent'ı uygulama kurar). Root girişi kilitli sunucularda, yöneticinin agent'la birlikte hazırladığı root olmayan izleme kullanıcısı da (örneğin `srvmon`) yazılabilir; aşağıdaki "Root olmayan kullanıcıyla bağlanmak" bölümüne bak.
2. **Giriş yöntemini seç:**

   | Yöntem | Ne zaman |
   |---|---|
   | **Password** | Sunucu root'un şifreyle girişine izin veriyorsa. "Use app key afterwards" açıkken uygulama kendi key'ini sunucuya ekler ve **şifreyi saklamaz**. |
   | **iPhone key** | Sunucuda şifreyle giriş kapalıysa (birçok Ubuntu sunucusunda varsayılan budur). Bkz. [Bölüm 5](#5-iphone-key-şifresiz-giriş). |
   | **Key file** | Mevcut bir private key'i (OpenSSH formatında, ed25519 veya RSA) içe aktarmak için. Önerilmez, çünkü private key telefona kopyalanmış olur. |

3. **Kurulum ayarlarını seç:**
   - Push alerts
   - Watch other servers (sunucular birbirinin açık olup olmadığını kontrol eder)
   - Container actions (uygulamadan start/stop/restart)
4. **Connect & install agent**'a bas. Uygulama sırasıyla şu adımları yapar:

   | Adım | Ne yapar |
   |---|---|
   | 1. Connect via SSH | Sunucuya bağlanır. İlk bağlantıda sunucunun host key'ini kaydeder. |
   | 2. Check system | Root olduğunu, işlemci mimarisini (amd64/arm64), systemd'yi ve Docker'ı kontrol eder. |
   | 3. Install app SSH key | (Sadece Password yönteminde) iPhone key'ini `authorized_keys` dosyasına ekler, şifreyi siler. |
   | 4. Upload agent | Agent'ı SFTP ile yükler ve sha256 ile dosyanın bozulmadığını doğrular. |
   | 5. Install & start service | `/usr/local/bin/srvmon-agent` dosyasını, `/etc/srvmon/config.json` ayarını ve systemd servisini kurar. |
   | 6. Health check | Agent'ın cevap verdiğini kontrol eder. |
   | 7. Register push alerts | APNs key'ini ve bu iPhone'u sunucuya kaydeder. |

Bir adım hata verirse ekranda hatanın açıklaması ve bir **Try again** butonu çıkar.

### Root olmayan kullanıcıyla bağlanmak (`srvmon`)

Bazı sunucularda root ile giriş kapalıdır (örneğin yönetim penceresi ve Authenticator kodu ister). Böyle bir sunucuda `srvmon` adında küçük bir kullanıcı açılır ve uygulama sunucuya onunla girer. Bu kullanıcı yalnızca agent'la konuşabilir; sudo'su yoktur, şifresi yoktur, sadece telefonun key'iyle girer. Root ayarlarına dokunulmaz.

Kurulum üç adımdır. Gereken her şeyi uygulama hazırlar:

1. **Uygulamada:** Servers → **+**. User alanına `srvmon` yaz, giriş yöntemi olarak **iPhone key**'i seç. Setup bölümünde **Server setup script**'e dokun.
2. **Sunucuda, bir kez, root olarak:** Açılan ekranda **Share binary** ile agent dosyasını Mac'e gönder (AirDrop) ve ekrandaki `scp` komutuyla sunucuya kopyala. Sonra **Copy script** ile scripti al ve sunucuda root olarak çalıştır. Script kullanıcıyı açar, telefonun key'ini ekler, agent'ı kurar ve en sonda `OK` yazar.
3. **Uygulamada:** Geri dön, **Connect to existing agent**'a bas. Bitti.

Bilmen gerekenler:
- Bu sunucuda agent güncellemesini uygulama yapamaz (root değil). Sarı şerit çıkınca yeni dosyayı kopyalayıp aynı scripti tekrar çalıştırırsın; kullanıcı, key ve ayarlar korunur.
- ··· menüsünde **Update agent** ve "Remove and uninstall agent" bu sunucuda görünmez.
- Agent root çalıştığı için telefonun key'i olan kişi uygulamadan dosya okuyup düzenleyebilir ve silebilir. Key telefondan hiç çıkmaz; telefon kaybolursa sunucuda `/home/srvmon/.ssh/authorized_keys` içindeki satırı sil.
- İkinci bir iPhone'u sunucuya eklemek için script gerekmez: Bölüm 5'teki "İkinci iPhone" adımlarına bak.
- Ayrıntılar ve sorun giderme: `docs/SRVMON-USER.md`.

## 5. iPhone key: şifresiz giriş

Uygulama ilk açılışta iPhone'da bir **ed25519 SSH key'i** üretir:
- **Private key** iPhone'un Keychain'inde saklanır ve telefondan hiç çıkmaz.
- **Public key** sunucuya eklenir. Mac'te `ssh-copy-id` ile yaptığın işin aynısı.

### Sunucuya eklemek (adım adım)

1. iPhone'da sunucu ekleme ekranında **iPhone key**'i seç ve **Copy command**'a bas.
   (Ya da: **Settings → This iPhone's SSH key → Copy public key**.)
2. Mac'te **Terminal**'i aç ve sunucuya her zamanki gibi bağlan:
   ```bash
   ssh root@SUNUCU_IP
   ```
3. Kopyaladığın komutu yapıştır (**⌘V**) ve **Enter**'a bas. Komut şuna benzer:
   ```bash
   mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo 'ssh-ed25519 AAAA… server-monitor-ios' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
   ```
   Ekranda bir şey yazmaması normal.
4. iPhone'a dön ve **Connect & install agent**'a bas.

**İpucu:** Telefonda kopyalanan metnin Mac'te yapışması için iki cihazda aynı Apple hesabı açık ve Bluetooth açık olmalı (Evrensel Pano). Olmazsa komutu kendine mesaj veya not olarak gönder.

### Key'in eklendiğini kontrol etmek

```bash
grep server-monitor-ios ~/.ssh/authorized_keys
```

### İkinci iPhone: başka bir telefonu aynı sunuculara bağlamak

Her iPhone'un kendi key'i vardır. İkinci telefonu sunuculara tek tek eklemek yerine, zaten bağlı olan telefon bunu yapar. Terminal ve root gerekmez.

1. **Yeni telefonda:** Settings → **This iPhone's SSH key**. Orada bir QR kod var.
2. **Bağlı telefonda:** Bu QR kodu **Kamera** uygulamasıyla okut. Server Monitor açılır, **Authorize iPhone** ekranı gelir. Hangi sunuculara eklenecekse seç, **Authorize**'a bas. Uygulama her sunucuda key'i `authorized_keys` dosyasına yazar (root ile bağlı olduğu sunucularda root'un, `srvmon` ile bağlı olduğu sunucularda `srvmon`'un dosyasına).
3. **Bağlı telefonda** ikinci bir QR kod çıkar: sunucu listesi. **Yeni telefonla** bunu okut. Server Monitor açılır, sunucuları gösterir, **Add**'e bas. Sunucular eklenir ve kendi key'iyle bağlanır. Hiçbir şey kurulmaz.

Telefonlar yan yana değilse QR yerine **Share link** ile linkleri gönderebilirsin; link diğer telefonda Server Monitor'ü açar. Key'i elle de yapıştırabilirsin: Settings → **Other iPhones** → key alanı → **Authorize**.

**Erişimi kesmek:** Settings → **Other iPhones** listesinde telefonun yanındaki **Revoke**. Key, eklendiği bütün sunuculardan silinir.

### Key'i bir sunucudan kaldırmak

```bash
sed -i '/server-monitor-ios/d' ~/.ssh/authorized_keys
```

## 6. Taslaklar: yarım kalan kurulumlar

- **Connect & install agent**'a bastığın anda sunucu **taslak** olarak kaydedilir. Şifre veya key iPhone Keychain'inde saklanır.
- Kurulum yarıda kalırsa ya da **Close**'a basarsan sunucu listede turuncu **"setup not finished"** kartıyla durur.
- Karta dokununca form, girdiğin bilgilerle dolu açılır. Gerekeni düzeltip tekrar deneyebilirsin.
- Silmek için kartın formunda en alttaki **Delete this server**'a bas ya da karta uzun bas → **Delete**.

## 7. Uygulamayı kullanmak

- **Servers:** Sorunlu sunucular en üstte listelenir. Kartlarda CPU, RAM, disk ve çalışan container sayısı görünür. Bağlantı koparsa kartta **Reconnect** butonu çıkar. Sunucudaki agent uygulamadakinden eskiyse kartta sarı **Agent update needed** şeridi ve **Update now** düğmesi çıkar; dokununca güncelleme başlar. İlerleme sayfasında **Continue in background** dersen şerit maviye döner ve o anki adımı ("Upload agent", "Health check"…) ilerleme çubuğuyla gösterir; dokununca sayfa geri açılır. Bitince şerit kendiliğinden kalkar; hata olursa kırmızı **Agent update failed** şeridi kalır, dokunup ayrıntıyı görünce kapanır.
- **Sunucu detayı:**
  - CPU, RAM ve disk göstergeleri, son 1 saatlik CPU grafiği.
  - **Docker kartı:** Docker'ın kendi sağlık durumu (motor cevap veriyor mu, `docker.service` çalışıyor mu, sorunlu container var mı), motor sürümü, çalışan / durmuş / sorunlu container ve imaj sayıları, container'ların sunucuya bindirdiği toplam CPU ve RAM yükü, son 1 saatte container CPU'sunun sunucu CPU'suna göre seyri. Karta dokununca **Containers** ekranı açılır: en üstte Docker motorunun durumu (dokununca motorun logları), altında filtre kutusu ve container listesi.
  - **Other services kartı:** Docker dışındaki systemd servisleri: kaç tanesi aktif, kaç tanesi çökmüş (çökenlerin adı kartta yazar). Tanınan servisler (Nginx, Apache, Caddy, MySQL/MariaDB, PostgreSQL, Redis, PHP-FPM, SSH, fail2ban, cron…) kartın altında durum noktalı çipler olarak görünür. Dokununca **Services** ekranı açılır: üstte **Known services** (tanınanlar, ikonlu), altında **All services** ve filtre kutusu. Ekip üyeleri (relay) bu kartı görmez.
- **Servis detayı (bir servise dokun):** Durum (Running / Stopped / Failed), **Start / Stop / Restart** butonları ve servisin journal logları. Stop ve Restart onay ister; Docker motorunda onay "bütün container'lar kapanır" der. Butonlar container işlemleriyle aynı anahtara bağlıdır (··· → **Container & service actions**). Güvenlik için agent `srvmon-agent`'a hiç dokunmaz; `ssh`/`sshd`, `systemd-logind` ve `dbus` durdurulamaz ve yeniden başlatılamaz (bağlantıyı keserdi), yalnızca başlatılabilir. Servis işlemleri için sunucuda agent 0.4.0 gerekir; eski agent'ta buton "Update it from the server list" der.
  - Filtre kutusu: `erp` yazınca adında "erp" geçenler, `erp prod` yazınca iki kelimeyi birden içerenler listelenir.
- **Container detayı:**
  - Durum, restart sayısı, bellek kullanımı.
  - **Start / Stop / Restart** butonları. Basınca ilerleme kartı adımları ve geçen süreyi gösterir.
  - Canlı loglar: **Follow** (otomatik kaydırma), **Errors** (sadece hata satırları) ve arama.
- **Health check (sunucu detayında):** O anda baştan yapılan 12 kontrol: telefonun bağlantı süresi, CPU, load, RAM, swap, diskler, inode, Docker, sorunlu container'lar, çökmüş servisler, son 24 saatteki OOM kill'ler, saat senkronu, bekleyen reboot ve diğer sunuculara erişim. Her satır yeşil, sarı veya kırmızı gösterilir; sorunlu satırlarda bir ipucu da yazar.
- **Disk analizi (Disk göstergesine dokun):**
  - **Docker:** İmajlar, build cache, volume'lar, container logları ve container katmanları ayrı ayrı gösterilir. Her birinde "reclaimable" (silinebilir) miktarı yazar.
  - **Folders:** Klasörlerin boyutu büyükten küçüğe sıralanır. Bir klasöre dokununca içine inersin.
  - **Largest files:** 50 MB'tan büyük dosyalar listelenir.
  - **Files:** Bulunduğun klasördeki dosyalar türüne göre bir rozetle (TSX, PDF, PNG…), boyut, değiştirilme zamanı, sahip ve izinleriyle listelenir. Bir dosyaya dokununca açılır (aşağıda).
  - **Silmek:** Klasör veya dosya satırını sola kaydır ya da uzun basıp **Delete…**'e bas. Onay ekranı boyutu gösterir ve silmenin kalıcı olduğunu söyler; klasör silerken klasörün adını yazman istenir. Bir container'ın mount ettiği veya çalışan bir sürecin içinde bulunduğu yollar kırmızı **In use** uyarısıyla işaretlenir.
  - Güvenlik için silinemeyen yerler: `/`, `/proc`, `/sys`, `/dev`, `/boot`, `/usr`, `/bin`, `/sbin`, `/lib*`, `/etc/srvmon`, `/run/srvmon`, `/var/lib/docker` ve bütün üst düzey klasörler (`/var`, `/etc`, `/home` gibi; içlerindeki öğeler silinebilir). Mount noktaları da silinmez.
- **Dosya görüntüleme ve düzenleme (Files listesinde bir dosyaya dokun):**
  - Dosya satır numaralarıyla gösterilir. Büyüteç ile arama yapılır; eşleşmeler sarı işaretlenir, ok tuşlarıyla aralarında gezilir.
  - **Edit** ile düzenleme moduna geçilir, **Save** ile kaydedilir. Agent önce `dosya.srvmon-bak-<tarih>` adıyla yedek alır (son 3 yedek tutulur), sonra dosyayı mod ve sahibini koruyarak atomik olarak yazar.
  - Dosya sen açtıktan sonra sunucuda değişmişse kaydetme reddedilir; uygulama **Reload** (kendi değişikliklerini at) veya **Overwrite anyway** (sunucudaki sürümü yedekleyip üstüne yaz) seçeneklerini sunar.
  - Sınırlar: 64 KB'tan büyük dosyalar ve sistem yolları salt okunurdur; 512 KB'tan büyük dosyaların yalnızca son 512 KB'ı gösterilir (büyük loglar için). İkili (binary) dosyalar gösterilmez.
  - **Eklemek (+ düğmesi):** **New file** boş bir editör açar, kaydedince dosya oluşur. **New folder** klasör oluşturur. **Upload from Files** telefondaki Dosyalar uygulamasından bir veya birkaç dosya seçtirir; dosya SFTP ile sunucuya gider, agent güvenlik listesine göre denetleyip yerine koyar. Aynı adda dosya varsa üstüne yazmaz, önce silmen gerekir. Dosya başına 200 MB sınırı var.
  - Ekip üyeleri (relay) dosya listesini, içeriğini göremez ve silemez; bu özellik yalnızca SSH ile bağlanan admin içindir.
  - Tarama sunucuda düşük öncelikle çalışır ve 10 dakika boyunca saklanır.
  - **Stop scan:** Tarama sürerken basınca sunucudaki `du` ve `find` işlemleri hemen sonlandırılır. Sonra **Scan again** ile yeniden başlatabilirsin.
- **Smart cleanup (Disk ekranında):**
  - **Safe** grubu varsayılan olarak seçilidir: Docker build cache, etiketsiz (`<none>`) imajlar, 50 MB üstü container logları (sıfırlanır, container çalışmaya devam eder), APT önbelleği, eski journal kayıtları (son 200 MB kalır), arşivlenmiş eski loglar, Composer/npm/yarn/pip/Go önbellekleri ve crash dump'lar.
  - **Review first** grubunu sen seçersin: kullanılmayan bütün Docker imajları ve `vendor/` / `node_modules/` klasörleri. Bir container'ın mount ettiği veya çalışan bir sürecin içinde bulunduğu klasör **kilitli** gösterilir ve silinemez.
  - Volume'lara, çalışan container'lara ve uygulama dosyalarına hiçbir zaman dokunulmaz.
  - **Stop:** Temizlik sürerken alttaki butona basınca, o an işlenen öğe bitince temizlik durur. Kalan öğeler "not run, stopped by user" olarak gösterilir. Bir öğe yarıda kesilmez, böylece hiçbir şey yarım kalmaz.
  - Tarama sürerken ne kadar zamandır çalıştığı ("Running for …") ve başlangıç saati gösterilir. 10 dakikayı geçerse uyarı çıkar; sunucu taramayı en geç 15 dakikada kendisi keser.
  - **Stop** telefonda beklemeyi her zaman hemen bitirir. Sunucuya ulaşılamazsa bunu ekranda söyler.
  - Disk analizi ve temizlikteki Stop butonları için sunucuda agent 0.3.2, dosya listesi ve düzenleme için 0.3.3, Docker kartındaki motor sürümü, imaj sayısı ve 1 saatlik container grafiği için 0.3.4, root olmayan kullanıcıyla dosya yüklemek için 0.3.5, servis start/stop/restart için 0.4.0 gerekir (··· → **Update agent** ya da Servers ekranındaki **Update now**).
- **Terminal (sunucu detayında):** Gerçek bir SSH terminali (xterm-256color). `htop` ve `vim` gibi tam ekran programlar çalışır. Altta hazır komut butonları var (`docker ps`, `df -h`, `free -h`, `htop`, `journalctl -f`, Ctrl-C…). Bağlantı koparsa **Reconnect**'e bas. Terminal sadece SSH ile bağlanılan sunucularda açılır; ekip üyeleri (relay) terminal kullanamaz.
- **··· menüsü (sunucu detayında):**
  - **Send test notification:** Test bildirimi gönderir.
  - **Container & service actions…:** Container ve servis start/stop/restart için şu anki durumu (ON/OFF) gösterir; onaylayınca açar veya kapatır.
  - **Update agent:** Agent'ı uygulamadaki sürüme günceller. Uygulama her güncellendiğinde bunu bir kez yap.
  - **Remove server:** Sunucuyu siler. İstersen agent'ı da sunucudan kaldırır.

## 8. Alarmlar ve push bildirimleri

Alarmları agent sunucuda kendisi kontrol eder. Uygulama kapalı olsa bile çalışır.

| Kural | Varsayılan |
|---|---|
| CPU | 5 dk boyunca %90 üzeri |
| Memory | 2 dk boyunca %85 üzeri |
| Disk | %85 üzeri |
| Container durdu | Çıkış kodu 0 veya 143 dışında, ya da bellek yetmediği için (OOM) kapatıldıysa |
| Container unhealthy | 60 sn |
| Restart loop | 10 dk'da 3 restart |
| systemd servisi failed | Anında |
| Başka bir sunucuya ulaşılamıyor | 2 dk |

- Aynı alarm en fazla **15 dakikada bir** tekrar bildirilir. Sorun düzelince "Resolved" bildirimi gelir.
- Kuralları **Alerts → Edit**'ten değiştirebilirsin. Değişiklik bütün sunuculara uygulanır.
- Bir container'ı alarmların dışında tutmak için ona şu Docker label'ını ekle: `srvmon.ignore=true`.

### Push'u açmak (ücretli Apple Developer hesabı gerekir)

1. **Apple Developer → Certificates, IDs & Profiles → Keys → +** yolunu izle, **Apple Push Notifications service (APNs)**'i seç ve `.p8` dosyasını indir.
2. Xcode'da **Team** olarak ücretli hesabı seç. **+ Capability → Push Notifications** ekle (`aps-environment` yetkisi).
3. Uygulamada **Settings → Push notifications → Import** ile `.p8` dosyasını seç, **Team ID**'yi gir ve **Save & deploy**'a bas.
4. Sunucu detayında **··· → Send test notification** ile dene.

Tek bir `.p8` key bütün sunucularda kullanılır. Key'i yenilemek için eski key'i Apple Developer'da iptal et, yenisini içe aktar ve **Save & deploy**'a bas.

## 9. Ekip erişimi (Team) ve relay

### Roller

| | Viewer | Operator | Admin |
|---|---|---|---|
| Sunucu sağlığı (CPU, RAM, disk) | ✓ | ✓ | ✓ |
| Kapsamdaki container'lar ve durumları | ✓ | ✓ | Tüm container'lar |
| Start / Stop / Restart | – | ✓ | ✓ |
| Container logları, systemd servisleri | – | – | ✓ |

**Kapsam (scope):** Her üye için ve her sunucu için ayrı belirlenir. Container adı, imaj adı veya compose projesi üzerinden eşleşir. `*` "her şey" anlamına gelir.

| Kalıp | Ne gösterir |
|---|---|
| `erp-*` | ERP-Backend, ERP-DB, ERP-Frontend… |
| `n8n` | Sadece adı (veya imajı / compose projesi) tam olarak `n8n` olanlar |
| `*db*` | Adında "db" geçen her şey |
| (boş) | Hiçbir container. Sadece sunucu sağlığı görünür. |

Kapsam dışındaki container'lar üyenin telefonuna **hiç gönderilmez**. Bu filtreleme sunucuda, agent tarafından yapılır.

### Relay'i kurmak (bir kez)

Relay internetten erişilebilen tek bir yerde çalışır, örneğin mevcut bir sunucuda, var olan reverse proxy'nin arkasında. Ayrıntılar `relay/README.md` dosyasında.

```bash
cd relay
echo "RELAY_ADMIN_TOKEN=$(openssl rand -base64 36 | tr -d '/+=')" > .env
docker compose up -d --build          # 127.0.0.1:8080 adresinde dinler
cat .env                              # bu token uygulamaya girilecek
```

Reverse proxy'de (Nginx) örneğin `monitor.appinsource.eu` için:

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_read_timeout 60s;
    proxy_buffering off;
}
```

### Ekibi kurmak (admin)

1. Uygulamada **Team → Set up relay**'e gir. Relay adresini (örn. `https://monitor.appinsource.eu`) ve admin token'ı gir, **Test & save**'e bas.
2. Her sunucu için **··· → Update agent** yap. Ekip özelliği için agent'ın **0.2.0 veya üstü** olması gerekir.
3. **Team → Servers on the relay** listesinde sunucunun yanındaki **Connect**'e bas. Yeşil "Connected to relay" yazısını gör.
4. **+ (Invite)**'a bas, ardından isim, rol ve her sunucu için kapsamı gir ve **Create invite**'a bas.
5. Çıkan **QR kodu** üyeye göster ya da **Share** ile linki gönder. QR tek kullanımlıktır ve **48 saat** geçerlidir.

### Üye olarak katılmak

1. Server Monitor uygulamasını kur (Bölüm 3).
2. QR kodu **iPhone kamerasıyla** okut. Uygulama açılır, **Join**'e bas.
   (Ya da: **Settings → Team → Paste invite link** ile linki yapıştırıp **Join**'e bas.)
3. İlk anda "access is being activated" mesajı görünebilir. Admin'in uygulaması açık olduğunda üye en geç 30 saniye içinde otomatik olarak etkinleşir.

### Üyeyi düzenlemek veya çıkarmak

**Team → üyeye dokun:** rolü ve kapsamı değiştir → **Save**. Erişimi tamamen kapatmak için **Revoke access**'e bas. İptal anında etkili olur.

## 10. Sorun giderme

### Sunucu eklerken

| Hata (uygulamada) | Sebebi | Çözüm |
|---|---|---|
| **Login failed… PermitRootLogin / PasswordAuthentication** (`allAuthenticationOptionsFailed`) | Sunucu root'un şifreyle girişini kabul etmiyor ya da şifre yanlış. | **iPhone key** yöntemini kullan (Bölüm 5). Sunucudaki ayarı görmek için: `sshd -T \| grep -Ei 'permitrootlogin\|passwordauthentication'` |
| **The server closed the connection… blocked this phone** (`Connection reset`) | Art arda başarısız girişlerden sonra sunucu (fail2ban) telefonun IP'sini engelledi. | **Try again'e tekrar tekrar basma.** 5–10 dk bekle ya da hosting panelinden engeli kaldır. Giriş sorununu çözmek için iPhone key kullan. Sunucuda: `fail2ban-client status sshd`, engeli kaldırmak için: `fail2ban-client set sshd unbanip TELEFON_IP` |
| **iOS blocked the connection…** (`NIOCore.IOError error 1`, EPERM) | Bağlantı telefondan çıkmadan engellendi, ya da engellenmiş bir IP'ye yeniden bağlanılmaya çalışıldı. | **Ayarlar → Hücresel → Server Monitor** açık olsun. VPN, reklam engelleyici veya DNS filtresi uygulamalarını kapatıp dene. Wi-Fi ile mobil veri arasında geçiş yap. Önceki satırdaki engel ihtimaline de bak. |
| **No answer from the server** (timeout) | Firewall SSH'a sadece belirli IP'lerden izin veriyor, ya da adres yanlış. | Hosting panelindeki firewall kurallarını kontrol et. Telefonu Mac ile aynı ağa bağlayıp dene. |
| **The server refused the connection** | O portta SSH çalışmıyor. | Doğru portu yaz. Sunucuda kontrol: `ss -tlnp \| grep ssh` |
| **host key changed** | Sunucu yeniden kuruldu ya da IP başka bir makineye geçti. | Bu beklenen bir durumsa sunucuyu uygulamadan sil ve yeniden ekle. Beklenmiyorsa bağlanma. |
| **srvmon@… did not accept this iPhone's key** | Key `srvmon`'un `authorized_keys` dosyasında yok (scriptteki `IPHONE_KEY` satırı boş kalmış olabilir) ya da sshd `AllowUsers` / `AllowGroups` ile `srvmon`'a izin vermiyor. | Sunucuda: `cat /home/srvmon/.ssh/authorized_keys` (telefonun key'i olmalı), `sshd -T -C user=srvmon,host=x,addr=1.2.3.4 \| grep -Ei 'allowusers\|allowgroups'`, `journalctl -u ssh \| grep srvmon` sebebi yazar. Key eksikse uygulamanın ürettiği scripti tekrar çalıştır. |
| **Agent update needed** şeridi script sonrası kalıyor | Script yeni dosyayı sunucuda bulamadı ("keeping the installed agent …") | Önce dosyayı sunucuya koy: şerit → **Get files** → **Send to server** (ya da `scp … :/tmp/srvmon-agent`), sonra scripti tekrar çalıştır. Çıktıda `== 3. agent` altında `…: OK` ve yeni sürüm görünmeli. |
| **Send to server: SFTP failed: permission denied** | `/var/lib/srvmon` klasörüne `srvmon` giremiyor (agent < 0.3.7) | Sunucuda: `chgrp srvmon /var/lib/srvmon && chmod 750 /var/lib/srvmon`. Agent 0.3.7'den itibaren kendisi düzeltir. |
| **… is not root and no agent answered for this user** | root dışında bir kullanıcıyla giriş yapıldı ama sunucuda bu kullanıcıya açık bir agent yok. | Ya `root` ile gir (uygulama kurar), ya da yönetici izleme kullanıcısını ve agent'ı `socket_group` ile hazırlasın (Bölüm 4, "Root olmayan kullanıcıyla bağlanmak"). |
| **systemd was not found** | Sistem systemd kullanmıyor (Alpine, bazı container ortamları). | Desteklenmiyor. |
| **Upload corrupted (checksum mismatch)** | Dosya yüklenirken bozuldu. | **Try again**. |
| **agent did not become healthy** | Servis başlamadı. | Sunucuda: `journalctl -u srvmon-agent -n 50` |

Yaşanmış bir örnek, adım adım (yanlış giden dört şey ve çözümleri): [docs/SENARYO-srvmon-kurulum-ve-guncelleme.md](docs/SENARYO-srvmon-kurulum-ve-guncelleme.md).

### Kullanırken

| Durum | Çözüm |
|---|---|
| Kartta **Connection lost** | **Reconnect**'e bas. Olmazsa sunucunun açık olduğunu ve SSH'ın çalıştığını kontrol et. |
| **Agent not reachable on the server** | Agent durmuş olabilir. Sunucuda: `systemctl status srvmon-agent`. Uygulamada: **··· → Update agent**. |
| Container listesi boş, "Docker not available" | Docker çalışmıyor ya da `/var/run/docker.sock` yok. Sunucuda: `systemctl status docker` |
| "Stop failed … allow_actions=false" | Bu sunucuda container actions kapalı. Hata kutusunun altındaki **Turn on container actions** butonuna bas (veya ··· → **Container actions…** → Turn on). |
| Bildirim gelmiyor | Ücretsiz Apple hesabında push yok (Bölüm 8). Ücretli hesapla: **Settings → Save & deploy**, sonra **Send test notification**. |
| Uygulama açılmıyor, "Untrusted Developer" | **Ayarlar → Genel → VPN ve Cihaz Yönetimi → Güven** |
| 7 gün sonra uygulama açılmıyor | Ücretsiz hesap imzasının süresi doldu. Xcode'dan tekrar **Run**'a bas. |
| Health check / Disk / Cleanup: "older agent" | Sunucudaki agent 0.3.0'dan eski. **··· → Update agent** |
| Disk ekranında "Browsing files needs agent 0.3.3" | Sunucudaki agent eski. **··· → Update agent** |
| Silerken "protected path" | O yol güvenlik listesinde (Bölüm 7, Disk analizi). Gerekiyorsa Terminal'den sil. |
| Silerken "contains a mount point" | Klasörün içinde başka bir dosya sistemi bağlı. Önce o mount'u kaldır ya da alt klasörleri tek tek sil. |
| Kaydederken "The file changed on the server" | Dosya sen açtıktan sonra değişmiş. **Reload** ile yeni sürümü gör veya **Overwrite anyway** ile üstüne yaz; eski sürüm `.srvmon-bak-` yedeğinde kalır. |
| Smart cleanup ev dizinlerindeki önbellekleri silemiyor | Agent'ın systemd servisinde `ProtectHome=read-only` var. 0.3.0 ile kurulan servis bu satırı kaldırıyor; **Update agent** yap. |
| Xcode'da "Download Metal Toolchain" ya da "SwiftTermBuildInfoPlugin" uyarısı | SwiftTerm paketi 1.10.1'e sabitlenmeli (proje dosyasında öyle). Xcode'da **File → Packages → Reset Package Caches** yap. |
| Xcode'da "Replace ServerMonitor?" sorusu | Telefonda eski sürüm çalışıyor. **Replace**'e bas. |
| Xcode'da "Personal development teams… do not support the Push Notifications capability" | Ücretsiz hesapla push yetkisi eklenemez. Signing & Capabilities'ten **Push Notifications**'ı kaldır (çöp kutusu ikonu). |

### Ekip (Team) özelliğinde

| Durum | Çözüm |
|---|---|
| Sunucu "Waiting for the agent to connect" | Agent eski sürümde olabilir: **··· → Update agent**. Sunucunun dışarıya HTTPS ile çıkabildiğini kontrol et: `curl -I https://monitor.appinsource.eu/healthz` |
| "Update the agent to 0.2" | **··· → Update agent** |
| Üye: "not activated on this server yet" | Admin uygulamayı açsın. Üye **Team** sekmesine girince otomatik olarak etkinleşir. |
| Üye: "server is offline" | O sunucunun agent'ı relay'e bağlı değil (yukarıdaki ilk satıra bak). |
| Üye: "request expired: check the phone's clock" | Telefonun saati 2 dakikadan fazla sapmış. **Ayarlar → Genel → Tarih ve Saat → Otomatik** |
| Davet: "invite expired" / "invite not valid" | Davetler 48 saat geçerli ve tek kullanımlık. Yeni davet oluştur. |
| Relay: "Not authorized by the relay" | Admin token yanlış. **Team → Relay**'den yeniden gir. |

## 11. Agent'ı sunucuda yönetmek

```bash
systemctl status srvmon-agent             # çalışıyor mu
journalctl -u srvmon-agent -f             # canlı log
srvmon-agent version                      # sürüm
srvmon-agent api GET /v1/summary | head   # agent'ın uygulamaya verdiği cevap
srvmon-agent api GET /v1/relay            # relay bağlantı durumu
cat /etc/srvmon/config.json               # ayarlar (APNs key ve üyeler dahil; sadece root okuyabilir)
```

### Agent'ı güncellemek

Uygulama her yeni sürümünde içinde yeni bir agent taşır. Sunucudaki agent eskiyse Servers ekranındaki kartta sarı **Agent update needed** şeridi çıkar. Güncelleme iki türlü olur:

**Root ile bağlı sunucular: otomatik.** Şeritteki **Update now**'a (ya da ··· → **Update agent**) bas. Uygulama yeni dosyayı SFTP ile yükler, sha256 ile doğrular, kurulum scriptini root olarak çalıştırır; ayar dosyası korunur, servis yeniden başlar. Yaklaşık 10 saniye.

**`srvmon` ile bağlı sunucular: agent 0.3.6'dan itibaren otomatik.** Uygulama root değildir ama agent'ın kendini güncelleme kapısı vardır. **Update now**'a basınca uygulama yeni dosyayı SFTP ile agent'ın yükleme klasörüne (`/var/lib/srvmon/upload`) atar ve agent'a dosyanın sha256'sını söyler. Agent root olarak: sha256'yı doğrular, dosyayı `version` ile çalıştırıp test eder, eskisini `/usr/local/bin/srvmon-agent.prev` olarak saklar, yenisini tek hamlede yerine koyar ve 2 saniye sonra kendini yeniden başlatır (ikisi de `systemd-run` ile, servisin kendi sandbox'ının dışında). Uygulama yeni sürüm cevap verene kadar bekler (en çok 45 s). Geri almak gerekirse sunucuda: `mv /usr/local/bin/srvmon-agent.prev /usr/local/bin/srvmon-agent && systemctl restart srvmon-agent`.

**`srvmon` ile bağlı sunucular, elle.** 0.3.5 ve öncesinden ilk geçişte (o sürümler kendini güncelleyemez; şeritte **Update now** yerine **Get files** çıkar) ya da otomatik güncelleme bir sebeple olmazsa. Kurulumla aynı üç adım:

1. **Yeni dosyayı sunucuya koy.** Şeritteki **Get files**'a ya da ··· → **Update on the server…**'a dokun ve **Send to server**'a bas: uygulama dosyayı `srvmon` olarak SFTP ile sunucuya gönderir, agent onu `/home/srvmon/srvmon-agent` olarak yerine koyar. Mac gerekmez. (Elle yol da duruyor: **Share binary** ile dosyayı Mac'e al ve `scp srvmon-agent-linux-amd64 root@SUNUCU:/tmp/srvmon-agent`.)
2. **Scripti root olarak çalıştır.** Aynı ekrandan **Copy script** ile aldığın scripti sunucuda root olarak yapıştır (MCP app'in root terminali, yönetim penceresi ya da başka bir root yolu). Script o sürümün sha256'sını taşır: dosyayı doğrular, `/usr/local/bin/srvmon-agent` olarak kurar, servisi yeniden başlatır ve `OK` yazar. Kullanıcıya, key'e ve `/etc/srvmon/config.json` dosyasına dokunmaz. Scriptin yaptığının kısa hali, elle yapmak istersen:
   ```bash
   echo "SHA256  /tmp/srvmon-agent" | sha256sum -c -                    # SHA256: SHA256SUMS dosyasındaki değer
   install -m 755 /tmp/srvmon-agent /usr/local/bin/srvmon-agent.new
   mv -f /usr/local/bin/srvmon-agent.new /usr/local/bin/srvmon-agent     # tek hamlede değişir, yarım dosya kalmaz
   rm -f /tmp/srvmon-agent
   systemctl restart srvmon-agent
   /usr/local/bin/srvmon-agent version                                   # yeni sürüm
   sudo -u srvmon /usr/local/bin/srvmon-agent api GET /v1/health | head -n1   # HTTP 200
   ```
3. **Kontrol.** Uygulamada sunucuyu aç; birkaç saniye içinde sarı şerit kaybolur (sürüm `/v1/summary` cevabından okunur).

Alıştırma için aynı sürümle de çalıştırabilirsin: script aynı dosyayı tekrar kurar, hiçbir şey bozulmaz.

Agent'ı kaldırmak için önerilen yol uygulamada **··· → Remove server → Remove and uninstall agent**. Elle kaldırmak için:

```bash
systemctl disable --now srvmon-agent
rm -f /etc/systemd/system/srvmon-agent.service /usr/local/bin/srvmon-agent
rm -rf /etc/srvmon            # ayarlar, APNs key ve üye listesi
systemctl daemon-reload
sed -i '/server-monitor-ios/d' ~/.ssh/authorized_keys   # iPhone key'i de kaldırmak için
```

## 12. Güvenlik

- **Sunucularda port açılmaz.** Agent sadece root'un okuyabildiği bir socket üzerinden çalışır. Relay'e bağlantıyı sunucu kendisi, dışarı doğru kurar.
- **Şifreler saklanmaz.** Password yönteminde şifre sadece kurulum sırasında kullanılır, sonra iPhone key'e geçilir. Bütün key ve şifreler iPhone Keychain'inde, sadece o cihazda tutulur.
- **Host key kontrolü:** İlk bağlantıda sunucunun host key'i kaydedilir. Sonradan değişirse uygulama bağlanmayı reddeder.
- **Ekip istekleri imzalanır.** Her üyenin telefonu kendi Ed25519 key'iyle her isteği imzalar. Agent bu imzayı, adminin SSH üzerinden gönderdiği üye listesiyle karşılaştırır. Relay ele geçirilse bile kimse yetkisi olmayan bir şeyi göremez veya değiştiremez. Eski bir isteği tekrar göndermek de engellenir.
- **Loglar ve servisler sadece admin rolüne açıktır**, çünkü loglarda şifre veya müşteri verisi bulunabilir.
- **Dosya yöneticisi yalnızca SSH ile bağlanan admin içindir.** Relay üzerinden gelen üyeler dosya isteklerinde 403 alır. Sistem klasörleri yazma ve silmeye kapalıdır; her kayıttan önce yedek alınır ve yazma atomiktir (yarım dosya kalmaz).
- **Uygulama kilidi:** Uygulama Face ID ile kilitlenir. **Settings → Security** bölümünden kapatılabilir.

## 13. Planlar: Free, Trial, Pro

Uygulama ürün olarak çıkınca üç planı olacak. Bugün satın alma yok; herkes Pro'dur ve hiçbir şey kilitli değildir. Satın alma (App Store, ücretli Apple hesabı gerekir) eklenince kurallar şunlar olacak:

| | Free | Trial (ilk 14 gün) | Pro |
|---|---|---|---|
| Sunucu | 1 | 1 | sınırsız |
| İzleme, Docker ve servis listeleri, health check, uygulama içi alarmlar | var | var | var |
| Terminal | yok | var | var |
| Dosya yöneticisi, disk analizi, smart cleanup | yok | var | var |
| Container ve servis start/stop/restart, servis kurma | yok | var | var |
| Push bildirimi | yok | var | var |
| Ekip (Team) ve relay | yok | var | var |

- Free "bak ama dokunma" demek: tek sunucuyu izlersin, değiştiren her şey Pro.
- Deneme süresi uygulamanın ilk açıldığı gün başlar. Tarih Keychain'de tutulur; uygulamayı silip yeniden kurmak süreyi sıfırlamaz.
- Deneme süresinde de tek sunucu eklenir; Pro'dan düşen ya da daha önce eklenmiş sunucular listede kalır ve izlenmeye devam eder, hiçbir veri silinmez. Sadece kilitli ekranlar "Pro gerekiyor" der.
- Kilitli bir özelliğe dokununca **Server Monitor Pro** sayfası açılır: planın, deneme bitiş tarihi ve Pro'nun içerdiği liste.
- **Settings → Plan → Simulate:** uygulamanın Free ya da Trial'da nasıl davrandığını görmek için. Sahip olduğun planı değiştirmez; **Off** gerçek plana döner.
- Sayılar (14 gün, 1 sunucu) ve kilitli özellik listesi tek dosyadadır: `ios/ServerMonitor/Services/Plan.swift`.

## 14. Marka yazımı: appinsource

- Marka adı **her zaman küçük harfle** yazılır: `appinsource`. "AppInSource", "AppInsource" gibi yazımlar yanlış.
- Logo yazısında yalnızca **in** mavidir:

  | Tema | app / source | in |
  |---|---|---|
  | Dark | beyaz `#FFFFFF` | PayPal mavisi `#009CDE` |
  | Light | siyah `#000000` | koyu mavi `#0070BA` |

- iOS'ta `BrandWordmark` bileşeni bunu otomatik olarak uygular (`ios/ServerMonitor/UI/Brand.swift`).

## 15. Geliştirme

```bash
# Agent
cd agent && make test            # testler (sahte Docker Engine dahil)
make ios-resources               # linux amd64/arm64 derle → ios/ServerMonitor/Resources/Agent

# Relay
cd relay && go vet ./... && go build .

# Uçtan uca (relay + agent + imzalı üye istekleri)
cd e2e && go test -v ./...
```

- `ios/ServerMonitor/Resources/Agent/` klasörü git'te **yoktur** (`.gitignore`). Projeyi yeni bir bilgisayarda klonladıktan sonra, Xcode'da ilk derlemeden önce Go kurulu olmalı ve `cd agent && make ios-resources` çalıştırılmalıdır; aksi hâlde uygulama paketine agent binary'si girmez ve **Install agent** çalışmaz.
- Agent'ın sürümü `agent/main.go` (`version`) ve `agent/Makefile` (`VERSION`) dosyalarında. Değiştirdikten sonra `make ios-resources` çalıştır ve uygulamayı yeniden derle. Ardından her sunucuda **··· → Update agent** yap.
- iOS projesi Citadel (SSH) paketini kullanır. Xcode paketi ilk açılışta indirir.
