# Senaryo: root girişi kilitli bir sunucuyu bağlamak ve agent'ını güncellemek

Bu sayfa, Romon MCP sunucusunda (217.160.39.208) yaşananları baştan sona anlatır: ne yaptık, ne gördük, neden oldu, nasıl çözdük. Amaç, benzer bir durumda kimseye sormadan sorunu tanıyıp çözebilmen. Her adımda **nerede** olduğun (telefonda mı, sunucuda mı) ayrıca yazılı.

İlgili sayfalar: kurulum için [SRVMON-USER.md](SRVMON-USER.md), uygulama için [README.md](../README.md) Bölüm 4 ve 11.

## Durum

- Sunucuda root ile SSH girişi bilinçli olarak kilitli: root key'leri sadece dashboard'daki yönetim penceresi açıkken veriliyor, üstüne şifre ve Authenticator kodu isteniyor. Uygulama ne pencere açabilir ne kod girebilir. Bu kilit kalacak.
- Çözüm: sunucuda yalnızca agent'la konuşabilen `srvmon` kullanıcısı. Uygulama sunucuya bu kullanıcıyla, telefonun key'iyle girer.
- Sunucuya root olarak girmek için iki yol vardı: yönetim penceresi + terminal, ya da MCP app'in içindeki root terminali. İkincisi daha kolay; aşağıda "root terminali" denen yer orası.

## Genel akış (sorunsuz hali)

| Sıra | Nerede | Ne yapılır |
|---|---|---|
| 1 | Telefonda | Servers → **+** → Name, Host, User `srvmon`, giriş **iPhone key** → **Server setup script** |
| 2 | Telefonda | **Share binary** ile agent dosyasını al (ya da sonraki güncellemelerde **Send to server**) |
| 3 | Sunucuda, root | Dosya `/tmp/srvmon-agent` olarak sunucuda olmalı; **Copy script** ile alınan scripti çalıştır; son satır `OK` |
| 4 | Telefonda | **Connect to existing agent** → sunucu kartı gelir |
| 5 | Telefonda, sonraki sürümlerde | Sarı şerit → **Update now** (agent ≥ 0.3.6). Daha eski agent'ta: **Get files** → **Send to server** → **Copy script** → sunucuda root olarak çalıştır |

Biz bu akışta dört yerde takıldık. Sırayla:

## 1. "Login failed (allAuthenticationOptionsFailed)"

**Nerede:** Telefonda, sunucu eklerken, "Connect via SSH" adımında.

**Ne yaptık:** Agent dosyasını `scp` ile sunucuya kopyaladık ve bunu "kurulum" sandık. Telefonda User `srvmon`, iPhone key ile **Connect** dedik.

**Ne gördük:** Kırmızı "Login failed". O zamanki mesaj şifreden ve root'tan bahsediyordu, yanıltıcıydı. (Artık mesaj "srvmon@… did not accept this iPhone's key" diyor ve neye bakılacağını söylüyor.)

**Neden:** Sunucuda `srvmon` kullanıcısı hiç yoktu. Dosyayı kopyalamak kullanıcı açmaz. Kullanıcıyı, key'i, sshd ayarını ve agent'ı **script** açar. Sunucuda kanıt:

```bash
id srvmon                                  # "no such user"
journalctl -u ssh -n 40 --no-pager | grep -i srvmon   # "Invalid user srvmon from <telefon IP>"
```

**Çözüm:** Telefonda **Server setup script → Copy script**, sunucuda root terminaline yapıştırıp çalıştırdık. Çıktının sonu:

```
0.3.5
HTTP 200
...
uid=1000(srvmon) gid=982(srvmon) groups=982(srvmon)
OK
```

**Ders:** Script çalışmadan **Connect**'e basma. Sunucuda hazır olup olmadığını üç komut söyler:

```bash
id srvmon                                                        # kullanıcı var mı
cat /home/srvmon/.ssh/authorized_keys                            # telefonun key'i içinde mi
sudo -u srvmon /usr/local/bin/srvmon-agent api GET /v1/health | head -n1   # HTTP 200 mü
```

Üçü de iyiyse giriş olur. Biri eksikse scripti (tekrar) çalıştır; script var olanı bozmaz.

## 2. "Connection refused" (sunucu bağlantıyı kapıdan çeviriyor)

**Nerede:** Telefonda, 1. sorunu çözdükten hemen sonra **Try again** dediğimizde.

**Ne gördük:** "The server closed the connection… Connection refused (errno 61)". Bu kez giriş reddedilmiyor, bağlantı hiç kurulamıyor.

**Neden:** 1. sorundayken dört kez başarısız giriş denemesi olmuştu ("Invalid user srvmon"). Sunucudaki **fail2ban** bunu saldırı sayıp telefonun IP'sini engelledi. fail2ban'in engeli tam olarak "connection refused" gibi görünür.

**Çözüm:** Sunucuda root olarak:

```bash
fail2ban-client status sshd                      # engellenen IP'ler
fail2ban-client set sshd unbanip 79.234.222.39   # telefonun IP'si (journal'daki "from <IP>")
```

Sonra telefonda **Try again** → bağlandı.

**Ders:** Bir giriş hatası aldığında **Try again'e üst üste basma.** Önce sunucudaki sebebi düzelt, sonra bir kez dene. Her başarısız deneme engel süresini uzatır. Telefon mobil veride ise IP farklıdır; `status sshd` çıktısındaki IP'yi kaldır.

## 3. Script çalıştı ama sarı "Agent update needed" şeridi kalktı kalkmadı

**Nerede:** Telefonda, uygulama 0.3.6'ya geçtikten sonra Romon MCP kartında. Sunucuda agent 0.3.5 idi.

**Ne yaptık:** Telefondan scripti kopyalayıp root terminalinde tekrar çalıştırdık. "İşlem tamam" dedik.

**Ne gördük:** Şerit aynen duruyor: "Server runs 0.3.5".

**Neden:** Script yeni agent dosyasını sunucuda bulamadı; o zaman eskisini olduğu gibi bırakır ve bunu yazar:

```
== 3. agent
no new file in /tmp/srvmon-agent or /home/srvmon/srvmon-agent; keeping the installed agent 0.3.5
```

Script yalnızca sunucuda **zaten duran** dosyayı kurar. Dosyayı sunucuya koymak ayrı bir adımdır (scp ya da uygulamadan **Send to server**).

**Ders:** Script çıktısının `== 3. agent` bölümünü oku. Orada `…: OK` (sha256 doğrulandı) ve `== 4. check` altında yeni sürüm numarası görünmeli. "keeping the installed agent" görürsen dosya sunucuda değildir.

## 4. "Send to server" başarısız: SFTP hatası

**Nerede:** Telefonda, şeritteki **Get files → Send to server**.

**Ne gördük:** Kırmızı "The operation couldn't be completed. (Citadel.SFTPMessage.Status error 1.)". (Artık mesaj sebebi söylüyor: "SFTP failed: permission denied…".)

**Neden:** Uygulama dosyayı `srvmon` olarak SFTP ile agent'ın yükleme klasörüne (`/var/lib/srvmon/upload`) yazar. Yükleme klasörü `srvmon` grubuna açıktı, ama bir üstü `/var/lib/srvmon` yalnızca root'a açıktı (`drwx------ root root`). Kapı kilitliyse içerideki oda açık olsa da giremezsin.

**Çözüm:** Sunucuda root olarak:

```bash
ls -ld /var/lib/srvmon /var/lib/srvmon/upload
chgrp srvmon /var/lib/srvmon && chmod 750 /var/lib/srvmon      # drwxr-x--- root srvmon
```

Sonra telefonda **Send to server** → yeşil "On the server: /home/srvmon/srvmon-agent". Agent 0.3.7 bu izni her açılışta kendisi düzeltir; başka sunucuda bu adım gerekmez.

**Ders:** SFTP `srvmon` olarak çalışır, yani sadece `srvmon`'un yazabildiği yerlere yazar. "permission denied" görürsen yol üzerindeki klasörlerin izinlerine bak (`ls -ld`).

## 5. Bitiş

Telefonda **Copy script** → root terminalinde çalıştır. Çıktı:

```
/home/srvmon/srvmon-agent: OK
...
0.3.7
HTTP 200
OK
```

Telefonda sunucu kartı: şerit gitti. Bundan sonra Romon MCP'de de **Update now** düğmesi çıkar; güncelleme telefondan tek dokunuşla olur (uygulama dosyayı gönderir, agent kendini değiştirip yeniden başlar, eskisi `.prev` olarak kalır).

## Bir dahaki sefere kontrol listesi

**Yeni sunucu eklemeden önce (sunucuda, root):**
- `id srvmon` kullanıcıyı gösteriyor mu?
- `cat /home/srvmon/.ssh/authorized_keys` içinde telefonun key'i var mı? (Telefonda Settings → This iPhone's SSH key'deki parmak iziyle karşılaştır: `ssh-keygen -lf /home/srvmon/.ssh/authorized_keys`.)
- `sudo -u srvmon /usr/local/bin/srvmon-agent api GET /v1/health | head -n1` → `HTTP 200`?

**Giriş hatası alınca:**
- Mesajı oku; artık ne olduğunu söylüyor. Bir kez düzelt, bir kez dene.
- "did not accept this iPhone's key" → yukarıdaki üç kontrol.
- "connection refused / server closed the connection" → `fail2ban-client status sshd`, gerekirse `unbanip`.
- Üst üste **Try again** yok.

**Sarı şerit kalkmayınca:**
- Script çıktısında `== 3. agent` ne diyor? "keeping the installed agent" ise dosya sunucuda yok.
- Sunucuda sürüm: `/usr/local/bin/srvmon-agent version`.
- Telefonda sürümün görünmesi için sunucuyu bir aç; sürüm her yenilemede okunur.

**Send to server olmayınca:**
- Mesaj "permission denied" ise: `ls -ld /var/lib/srvmon /var/lib/srvmon/upload` → `root srvmon` ve `750` / `770` olmalı.
- Olmuyorsa elle yol: **Share binary** → Mac → `scp … root@SUNUCU:/tmp/srvmon-agent`; script iki yere de bakar.

**Geri almak gerekirse (sunucuda, root):**
```bash
mv /usr/local/bin/srvmon-agent.prev /usr/local/bin/srvmon-agent && systemctl restart srvmon-agent
```

## Komut sözlüğü

| Komut | Ne söyler |
|---|---|
| `id srvmon` | Kullanıcı var mı, hangi gruplarda (docker/sudo olmamalı) |
| `journalctl -u ssh -n 40 --no-pager \| grep -i srvmon` | sshd girişi neden reddetti ("Invalid user", "Failed publickey", "Accepted publickey") |
| `fail2ban-client status sshd` | Engellenen IP'ler |
| `/usr/local/bin/srvmon-agent version` | Sunucudaki agent sürümü |
| `sudo -u srvmon /usr/local/bin/srvmon-agent api GET /v1/health \| head -n1` | Agent `srvmon`'a cevap veriyor mu (`HTTP 200`) |
| `systemctl status srvmon-agent` / `journalctl -u srvmon-agent -n 50` | Servis çalışıyor mu, neden durdu |
| `ls -la /run/srvmon/` | Soket `root srvmon` ve `srw-rw----` mi |
| `ls -ld /var/lib/srvmon /var/lib/srvmon/upload` | Yükleme klasörü `srvmon`'a açık mı |
