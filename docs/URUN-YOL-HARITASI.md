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

## 3. Relay: şu anki plan

**Ne:** Ekip üyelerinin ve Mac programının kullanacağı posta kutusu. Sunucular ona dışarıdan bağlanır, port açılmaz.

**Nerede:** MCP sunucusundaki kişisel workspace'te, bir proje olarak. Sunucunun kuralı, projelerin sunucunun kendisine kurulmamasını, workspace'ten yayınlanmasını söylüyor. Bu yüzden `docker compose` ile doğrudan sunucuya kurmuyoruz.

**Kurulum adımları:** Bölüm 4.

**Taşınabilirlik:**
- Relay tek bir programdır. Bütün durumu `relay.json` dosyasındadır, şifresi `admin-token` ya da `.env` içindedir.
- Taşıma testi yapıldı: veri klasörü kopyalanıp program başka yerde başlatıldığında durum birebir aynı kaldı (2026-11-04, yerel test).
- Docker'lı sunucularda `relay/backup.sh` ve `relay/restore.sh` kullanılır. Bu iki script henüz gerçek Docker'da denenmedi.
- Adres aynı kalırsa taşıma sunuculara ve telefonlara görünmez.
- **Adres değişirse** her sunucuda relay ayarı yeniden yazılır ve üyelerin yeniden davet alması gerekir. Bu yüzden adres seçimi önemlidir.

**Bilinen riskler, ilk kurulumda denenecek:**
- Yayın adresi `romon-mcp.com` altında olur, `appinsource.eu` altında olmaz. Ürün çıkınca kendi adresimize geçmek bir taşıma demektir.
- Yayın **public** olmalı. Giriş ekranı olan bir yayına uygulama ve agent bağlanamaz.
- Yayın proxy'sinin 25 saniyelik bekleyen istekleri kesip kesmediği bilinmiyor.
- Konteyner yeniden başlarsa relay'in kendiliğinden açılıp açılmadığı bilinmiyor.
- Proje şirket projesi olarak açılır. Kişisel proje için ayrı izin gerekir.
- Workspace şirket sunucusu ve şirket hesabıdır. Müşteri trafiği için bu yer geçicidir.

## 4. Relay'i workspace'te başlatmak

1. Mac'te paketi üret:
   ```sh
   relay/make-workspace-zip.sh
   ```
   Çıktı `~/Downloads/srvmon-relay-workspace.zip` olur.
2. Dashboard'da **Projects → New project → Upload existing project** ile yükle. Veritabanı gerekmez.
3. Test sunucusunu başlat. Komut paketteki CLAUDE.md dosyasında yazılıdır.
4. Yayını **public** yap, kısa adres olarak `monitor.romon-mcp.com` iste.
5. Kontrol et:
   ```sh
   curl -s https://monitor.romon-mcp.com/healthz
   ```
   Cevap `{"ok":true}` olmalı.
6. Şifreyi al: projede `data/admin-token` dosyası. Uygulamada **Team → Set up relay** ekranına adresi ve şifreyi gir.
7. Sunucuları relay'e kaydet, bir üyeyi davet et ve bir dakika bekleyip bağlantının kopmadığına bak.

`data/` klasörü git'e girmez. İçinde şifre ve üye bilgisi var.

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
| Relay | Kod hazır, kurulmadı. Bölüm 4. |
| 24 saatlik geçmiş | Sırada. |
| iPad | Sırada. |
| Servis kurma | Sırada. Plan kilidi hazır. |
| Demo sunucu | Sırada. |
| Mac programı | Relay'den sonra. |
| Windows | Mac'ten sonra. |
| Yönetim aracı | Kapsam konuşulacak. |
| Impressum | Site yayınından önce gerekli. Bilgileri Süleyman verecek. |
| Apple hesabı, TestFlight, push, App Store | Ürün bittikten sonra. |
| GitHub reposu | Hâlâ Public olabilir. Private yapılmalı ve bir LICENSE kararı verilmeli. |

## 8. Küçük teknik notlar

- Relay'in deneme sınırı istemci adresini `X-Forwarded-For`'dan okuyor. Proxy bu başlığı temizlemiyorsa adres sahte gösterilebilir. Şifre 32 karakterli rastgele olduğu için risk küçük, ama müşteri trafiğinden önce düzeltilmeli.
- Relay'in Docker imajında `/data` root'a aitti ve yazılamayabilirdi. 2026-11-04'te düzeltildi, gerçek Docker'da henüz denenmedi.
