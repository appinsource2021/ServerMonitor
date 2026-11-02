# Server Monitor: sunucuda `srvmon` kullanıcısı

Server Monitor, sunucularını iPhone'dan izleyen bir uygulamadır. Sunucuya doğrudan "root" olarak girmesi gerekmez. İzleme, sunucuda tek bir iş için açılmış **`srvmon`** adlı kullanıcı üzerinden yapılır. Bu sayfa, izlemek istediğin bir sunucuda bu kullanıcının nasıl hazırlanacağını anlatır.

## Nasıl çalışır

- Sunucuda **srvmon-agent** adlı küçük bir program çalışır. CPU, RAM, disk, Docker container'ları, servisler ve logları okur.
- Agent **hiçbir port açmaz.** Sadece sunucunun içinde, yerel bir soket üzerinden dinler.
- iPhone sunucuya **SSH** ile, `srvmon` kullanıcısıyla bağlanır ve her soruyu bu soket üzerinden agent'a sorar.
- `srvmon` kullanıcısı şifreyle giremez; yalnızca telefonun kendi ürettiği **SSH key**'i ile girer. Telefonun gizli anahtarı telefondan hiç çıkmaz.
- `srvmon` kullanıcısının sunucuda **sudo yetkisi yoktur**, docker grubunda değildir, port yönlendirme yapamaz. Tek yapabildiği agent'la konuşmaktır.
- Sunucunun root girişi nasıl ayarlıysa öyle kalır. Bu kurulum root ayarlarına dokunmaz.

İki yol var:

| | Ne zaman | Ne yaparsın |
|---|---|---|
| **Uygulama kurar** | Sunucuya root ile SSH yapılabiliyorsa | Uygulamada sunucuyu root ile eklersin; agent'ı uygulama kurar. Bu sayfaya gerek yok. |
| **Sen hazırlarsın** (bu sayfa) | Root girişi kapalı, iki aşamalı doğrulama istiyor ya da uygulamaya root vermek istemiyorsan | Aşağıdaki adımlarla `srvmon` kullanıcısını ve agent'ı bir kez kurarsın. |

## Gerekenler

- Sunucuda **bir kez root** yetkisi (terminalden, yönetim panelinden ya da bir yönetici aracılığıyla).
- Sunucuda **systemd** (Ubuntu, Debian, RHEL ailesi; Alpine desteklenmez).
- Uygulamanın verdiği iki şey. İkisi de uygulamada hazır üretilir: **Servers → + → User** alanına `srvmon` yaz → **Server setup script**'e dokun.
  1. **Agent dosyası** (`srvmon-agent-linux-amd64` ya da `arm64`). "Share binary" ile Mac'e AirDrop'la ya da Dosyalar'a kaydet.
  2. **Kurulum scripti.** Telefonun SSH key'i içine yazılmış olarak gelir. "Copy script" ya da "Share script".

## Adımlar

1. **Agent dosyasını sunucuya kopyala.** Uygulamadaki scp komutunu kullan; dosya sunucuda `/tmp/srvmon-agent` olmalı:

   ```bash
   scp srvmon-agent-linux-amd64 root@SUNUCU:/tmp/srvmon-agent
   ```

2. **Scripti sunucuda root olarak çalıştır.** Scripti bir dosyaya yapıştırıp `sh srvmon-setup.sh` de, ya da içeriğini doğrudan root terminaline yapıştır.

3. **Son satırı kontrol et.** Script kendini test eder ve en sonda `OK` yazar. `HTTP 200` satırı agent'ın `srvmon` kullanıcısına cevap verdiğini gösterir.

4. **Uygulamada bağlan.** Sunucu ekleme ekranında User `srvmon`, giriş yöntemi **iPhone key**, sonra **Connect to existing agent**. Uygulama hiçbir şey kurmaz; agent'ın cevap verdiğini görüp sunucuyu kaydeder.

## Script tam olarak ne yapar

1. `srvmon` grubunu ve kullanıcısını açar. Şifresi kilitlidir; ev dizini `/home/srvmon`.
2. Telefonun public key'ini `/home/srvmon/.ssh/authorized_keys` dosyasına ekler. Aynı key ikinci kez eklenmez.
3. `/etc/ssh/sshd_config.d/40-srvmon.conf` dosyasını yazar: `srvmon` için şifre ve interaktif giriş kapalı, TCP/agent/X11 yönlendirme kapalı. `sshd -t` ile ayarı doğrulayıp sshd'yi yeniden yükler. Diğer kullanıcıların ayarına dokunmaz.
4. Agent dosyasının sha256 özetini doğrular ve `/usr/local/bin/srvmon-agent` olarak kurar.
5. `/etc/srvmon/config.json` yoksa oluşturur: sunucu adı, soket yolu, `"socket_group": "srvmon"` ve `"allow_actions": true` (uygulamadan container start/stop/restart). Dosya varsa olduğu gibi bırakır.
6. `srvmon-agent` systemd servisini yazar, açılışta başlayacak şekilde etkinleştirir ve başlatır. Servis root olarak çalışır (Docker soketi ve journal için gerekir), `/run/srvmon/agent.sock` soketini `root:srvmon 0660` izinleriyle açar.
7. Kendini test eder: agent sürümü, `srvmon` olarak sağlık sorgusu, soket izinleri, kullanıcının grupları.

Scripti **tekrar çalıştırmak güvenlidir**: kullanıcı, key'ler ve ayar dosyası korunur. Agent güncellemesi de böyle yapılır: yeni agent dosyasını `/tmp/srvmon-agent` olarak kopyala, scripti tekrar çalıştır. Uygulama sürüm eskiyince sunucu kartında sarı bir şerit gösterir.

## Birden fazla iPhone

Her telefonun kendi key'i vardır. İkinci telefonda da aynı yolu izle: o telefonun uygulamasından scripti al ve sunucuda çalıştır. Script o telefonun key'ini ekler, öncekileri korur.

## Güvenlik notları

- `srvmon` kullanıcısı shell'de hiçbir root yetkisi almaz. Ama agent root olduğu için, uygulama üzerinden agent'ın bütün özellikleri kullanılabilir: container'ları durdurup başlatmak, logları okumak, dosya yöneticisiyle dosya okumak, düzenlemek, silmek ve yüklemek (sistem yolları ve `/etc/srvmon` korumalıdır). **Telefonun key'i kimdeyse bu yetki ondadır.** Telefonu kaybedersen key'i `/home/srvmon/.ssh/authorized_keys` dosyasından sil.
- Container actions istemiyorsan `/etc/srvmon/config.json` içinde `"allow_actions": false` yap ve `systemctl restart srvmon-agent` de.
- Kurulum hiçbir port açmaz, firewall'a dokunmaz, root girişini değiştirmez.

## Kaldırmak

```bash
systemctl disable --now srvmon-agent
rm -f /etc/systemd/system/srvmon-agent.service /usr/local/bin/srvmon-agent
rm -rf /etc/srvmon /var/lib/srvmon /etc/ssh/sshd_config.d/40-srvmon.conf
systemctl daemon-reload && sshd -t && systemctl reload ssh
userdel -r srvmon; groupdel srvmon 2>/dev/null
```

## Sorun giderme

| Belirti | Sebep | Çözüm |
|---|---|---|
| Script `ERROR: /tmp/srvmon-agent missing` diyor | Agent dosyası kopyalanmamış | 1. adımı yap. |
| `sha256sum: WARNING: 1 computed checksum did NOT match` | Dosya bozuk ya da uygulamadakiyle aynı sürüm değil | Dosyayı uygulamadan yeniden paylaş ve kopyala. Script de aynı uygulama sürümünden gelsin. |
| Uygulama: **srvmon is not root and no agent answered for this user** | Agent kurulmamış ya da `socket_group` ayarı yok | Scripti çalıştır; `sudo -u srvmon /usr/local/bin/srvmon-agent api GET /v1/health` sunucuda `HTTP 200` vermeli. |
| Uygulama: giriş hatası (`Permission denied (publickey)`) | Key eklenmemiş ya da başka telefonun key'i | O telefonun scriptini çalıştır. Sunucuda `journalctl -u ssh` içinde `Accepted publickey for srvmon` görünmeli. |
| Dosya yükleme izin hatası veriyor | Agent 0.3.5'ten eski | Agent'ı güncelle (scripti yeni dosyayla tekrar çalıştır). |
