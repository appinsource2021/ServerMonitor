# Server Monitor: ürün yol haritası ve kararlar

Bu dosya ürünle ilgili bütün kararların tek kaynağıdır. Yeni bir karar alındığında önce buraya yazılır.
Son güncelleme: 2026-11-04.

## 1. Ürünün amacı

Herhangi bir sunucunun durumunu telefondan izlemek, analiz etmek ve gerektiğinde kolayca müdahale etmek.
Çıkış noktası gerçek bir olay: acil bir serviste sadece terminal veren bir uygulamayla, küçük klavyede işi bitirememek.
Bu yüzden ürünün sözü şu: **terminale düşmeden sorunu gör ve çöz.** Terminal son çare olarak yanında durur.

## 2. Alınan kararlar

| Tarih | Karar |
|---|---|
| 2026-11-03 | Apple hesabı, App Store ve satın alma işleri ürün bittikten sonra yapılacak. |
| 2026-11-03 | App Store incelemesi ve ekran görüntüleri için uygulamada **demo sunucu** olacak. |
| 2026-11-03 | Planlar: **Free** 1 sunucu, sadece izleme. **Trial** 14 gün, her özellik açık, yine 1 sunucu. **Pro** sunucu sayısına göre. |
| 2026-11-03 | Listede duran sunucular hiçbir planda silinmez. Sadece yenisi eklenemez. |
| 2026-11-03 | Telefondan servis kurma olacak, ama sadece temel kurulum. Ayar ve kullanım senaryoları kapsam dışı. |
| 2026-11-04 | Mac ve Windows da desteklenecek. Önce Mac. |
| 2026-11-04 | Mac için ayrı bir **Server Monitor for Mac** programı yapılacak. Port açmadan dışarı bağlanacak, eşleştirme anahtarıyla telefona bağlanacak. |
| 2026-11-04 | Relay şimdilik **MCP sunucusunda** çalışacak, ama **taşınabilir** olmak zorunda. |
| 2026-11-04 | Relay'in hangi sunucuda çalışacağı ileride bir **yönetim aracından** seçilecek. |
| 2026-11-04 | **Merkezi relay yok.** Her kullanıcı kendi relay'ini kendi makinesine kurar. Kontrol uygulamadadır, ürünün bağlı olduğu bir kaynak yoktur. |
| 2026-11-04 | Kurulum **soru-cevaplı bir asistanla** yapılır. Nasıl yapıldığı resmi sayfada anlatılır. |

## 3. Relay modeli

**Ne:** Ekip üyelerinin ve Mac programının kullanacağı posta kutusu. Sunucular ona dışarıdan bağlanır, port açılmaz.

**Ürün modeli:** Relay'i kullanıcı kendisi kurar. Bunun sonuçları:
- appinsource müşteri verisi taşımaz, sitedeki "arka ucumuz yok" sözü doğru kalır.
- Sunucu maliyeti ve bakım sorumluluğu kullanıcıdadır.
- Relay kapanırsa sadece o kullanıcının ekibi etkilenir.
- Bedeli: kullanıcının bir makinesi ve alan adı olmalı. Mac programı için de relay şarttır. Sunucusu olmayan bir Mac kullanıcısı için ileride **barındırılan relay** seçeneği düşünülebilir. Bu, Pro'ya ek bir hizmet olur ve ayrı karar ister.

**Taşınabilirlik:**
- Relay tek bir programdır. Bütün durumu `relay.json` dosyasındadır, şifresi `admin-token` ya da env dosyasındadır.
- Taşıma testi yapıldı: veri klasörü kopyalanıp program başka yerde başlatıldığında durum birebir aynı kaldı (2026-11-04, yerel test).
- Docker'lı sunucularda `relay/backup.sh` ve `relay/restore.sh` kullanılır. Bu iki script henüz gerçek Docker'da denenmedi.
- Adres aynı kalırsa taşıma sunuculara ve telefonlara görünmez.
- **Adres değişirse** her sunucuda relay ayarı yeniden yazılır ve üyelerin yeniden davet alması gerekir.

## 4. Kurulum asistanı ve Süleyman'ın relay'i

**Asistan bugün:** `relay/setup.sh`. Terminalde sırayla sorar: alan adı, port, web proxy, onay. Sonra kurar, test eder, adresi ve şifreyi yazar. Yalnızca prova modunda denendi, gerçek bir sunucuda henüz çalıştırılmadı. Dağıtım paketi `relay/make-release.sh` ile `official/downloads/` altına üretilir. Anlatım `official/relay.html` sayfasındadır.

**Asistan için taslak plan:**
1. Terminal asistanını gerçek bir sunucuda denemek.
2. Aynı soruları uygulamanın içine taşımak: **Team → Set up relay → Install on one of my servers**. Uygulama SSH ile girer, soruları ekranda sorar, şifreyi kendisi kaydeder. Kullanıcı terminal görmez.
3. Sunucuya agent kurulumunu da aynı soru-cevap diliyle göstermek.
4. Yönetim aracı geldiğinde aynı adımları oradan da sunmak.

**Süleyman'ın kendi relay'i:** MCP workspace'inde **#ST6000 Server Monitor Relay** projesi. Sunucunun kuralı projelerin sunucunun kendisine kurulmasını yasaklıyor, bu yüzden workspace'te düz süreç olarak çalışıyor.
- Durum (2026-11-04): çalışıyor, ama yayın sadece Süleyman'a açık. Gerçek kullanım için public olmalı.
- Adres: `server-monitor-relay-stopaloglu.dev.romon-mcp.com`. Kısa adres olarak `monitor.romon-mcp.com` düşünülüyor.
- Şifre projedeki `data/admin-token` dosyasında. `data/` git'e girmez, çünkü proje şirket reposuna gidiyor.

**Public açılınca denenecekler:**
- Yayın proxy'si 25 saniyelik bekleyen istekleri kesiyor mu?
- Konteyner yeniden başlayınca relay kendiliğinden açılıyor mu?
- Burası şirket hesabı ve şirket sunucusu. Bu yüzden geçicidir, kendi makinemize taşınacak.

## 5. Yönetim aracı (management tool)

Süleyman'ın isteği: resmi web sitesinin yanında bir yönetim aracı olsun, relay'in kurulacağı sunucu oradan seçilsin.

Taslak kapsam:
- Relay'in hangi sunucuda çalıştığını görmek, başka sunucuya kurmak ve taşımak.
- Relay sağlığı: kaç sunucu ve üye bağlı, son bağlantılar.
- İleride lisans, plan ve müşteri yönetimi.

Açık sorular: web panelinin kendisi nerede çalışacak, kim girecek, uygulamadaki relay asistanıyla işi nasıl bölüşecek. Bunlar başlamadan önce konuşulacak. Henüz kod yok.

## 6. Server Monitor for Mac

Akış:
1. Program kurulur, menü çubuğunda ikon olarak durur.
2. QR ve kısa eşleştirme kodu gösterir.
3. Telefonda **Add Mac** ile QR okutulur.
4. Mac o telefonu kaydeder ve sadece ondan gelen imzalı istekleri kabul eder.

Şartlar:
- **Relay çalışıyor olmalı.** Mac'in ulaşılabilir olmasının tek yolu o.
- Eşleştirme kodu tek kullanımlık ve kısa ömürlü olmalı. Mac'te "bu telefona izin ver?" onayı çıkmalı. Eşleşen telefonlar listelenip iptal edilebilmeli.
- Veri Mac ile telefon arasında **uçtan uca şifrelenmeli**. Relay okuyamadığı zarfları taşımalı. Başkalarının bilgisayarları söz konusu olunca bu şart.
- Terminal bugünkü posta kutusu yöntemiyle çalışmaz, relay'e sürekli açık bağlantı eklenmeli.
- Mac uykudayken görünmez.
- Başkalarına dağıtmak için ücretli Apple hesabı gerekir.

Sıra: izleme ve QR eşleştirme → uçtan uca şifreleme → terminal ve dosyalar. Sonra aynı yöntem Windows'a ve modem arkasındaki Linux makinelere uygulanır.

**Ürün etkisi:** Relay müşteriler için işletilirse ürün bir hizmete dönüşür. Maliyet ve bakım doğar, aboneliğin en güçlü gerekçesi de bu olur.

## 7. Durum

| İş | Durum |
|---|---|
| Plan katmanı | Bitti. Satın alma kapalı, herkes Pro. |
| Bilinen servisler, start/stop/restart | Bitti (agent 0.4.0). Gerçek sunucuda denenmeli. |
| Güncellemenin kartta görünmesi | Bitti. |
| Süreç listesi | Bitti (agent 0.4.1). Gerçek sunucuda denenmeli. |
| Web sitesi | `official/` klasöründe hazır, yayınlanmadı. Yeni özellikler (süreçler, servisler) eklenmeli. Gizlilik metni plana göre gözden geçirilmeli. |
| Relay | #ST6000 projesinde çalışıyor, public açılması bekleniyor. Bölüm 4. |
| Kurulum asistanı | Terminal sürümü yazıldı, gerçek sunucuda denenmeli. Uygulama içi sürüm sırada. |
| Resmi sayfa `relay.html` | Yazıldı, site ile birlikte yayınlanacak. |
| 24 saatlik geçmiş | Sırada. |
| iPad | Sırada. |
| Servis kurma | Sırada. Plan kilidi hazır. |
| Demo sunucu | Sırada. |
| Mac programı | Relay'den sonra. |
| Windows | Mac'ten sonra. |
| Yönetim aracı | Kapsam konuşulacak. |
| Impressum | Site yayınından önce gerekli. Bilgileri Süleyman verecek. |
| Apple hesabı, TestFlight, push, App Store | Ürün bittikten sonra. |
| GitHub reposu | 2026-11-04'te hâlâ Public. Private yapılmalı ve bir LICENSE kararı verilmeli. |

## 8. Küçük teknik notlar

- Relay'in deneme sınırı istemci adresini `X-Forwarded-For`'dan okuyor. Proxy bu başlığı temizlemiyorsa adres sahte gösterilebilir. Şifre 32 karakterli rastgele olduğu için risk küçük, ama müşteri trafiğinden önce düzeltilmeli.
- Relay'in Docker imajında `/data` root'a aitti ve yazılamayabilirdi. 2026-11-04'te düzeltildi, gerçek Docker'da henüz denenmedi.
