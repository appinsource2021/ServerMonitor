# Brifing: Server Monitor için root olmayan izleme kullanıcısı (`srvmon`)

**Kimden:** Süleyman Topaloğlu (Server Monitor iOS uygulaması)
**Kime:** MCP dev server projesinin asistanı
**Sunucu:** `A519A07` · 217.160.39.208 · Ubuntu 26.04.1 · OpenSSH 10.2

---

## 1. Ne yapmak istiyoruz

**Server Monitor**, sunucuları iPhone'dan izleyen bir uygulama. Gösterdikleri: CPU, RAM, disk, Docker container'ları ve durumları, container logları, systemd servisleri ve alarmlar.

Çalışma şekli:
- Her sunucuda **srvmon-agent** adında küçük bir Go programı çalışır.
- Agent **hiç port açmaz**. Sadece yerel bir unix socket üzerinden dinler: `/run/srvmon/agent.sock`.
- iPhone sunucuya **SSH** ile bağlanır ve her istekte `/usr/local/bin/srvmon-agent api GET /v1/summary` gibi bir komut çalıştırır. Komutun çıktısı JSON'dur.

Bu sunucuyu da uygulamaya eklemek istiyorum. Bunun için **root olmayan, sadece izleme yapabilen** bir kullanıcı gerekiyor.

Bu kullanıcı iki yerden oluşturulabilmeli:
1. **Kurulum asistanında:** Sunucu kurulurken "Server Monitor erişimini aç" gibi bir adım olarak.
2. **Dashboard'dan, sonradan:** Ben izlemeyi açmak istediğimde dashboard kullanıcıyı oluşturmalı ve bana bağlantı bilgilerini (host, port, kullanıcı adı, giriş yöntemi) göstermeli.

## 2. Neden root ile olmuyor (sorun ne)

Bu sunucuda root SSH girişi bilinçli olarak kilitli (`/etc/ssh/sshd_config.d/30-mcp-root-gate.conf`):

```
Match User root
    AuthorizedKeysFile none
    AuthorizedKeysCommand /usr/local/sbin/mcp-root-keys
    AuthenticationMethods publickey keyboard-interactive
```

Bu ayarın sonuçları:
- Root key'leri **sadece dashboard'da "server administration" penceresi açıkken** verilir (`/run/mcp-root-window`).
- Bunun üstüne **şifre ve Google Authenticator kodu** da istenir (`pam_google_authenticator`).
- `~/.ssh/authorized_keys` root için **okunmaz**.

iPhone uygulaması pencere açtıramaz, TOTP kodu da giremez. Bu yüzden şu sırayla bir döngü oluşuyor:
1. Bağlantı doğrulama aşamasında takılıyor. Kayıtta: `Timeout before authentication` (`LoginGraceTime 30`).
2. OpenSSH 10'un `PerSourcePenalties` özelliği IP'yi cezalandırıyor. Kayıtta: `penalty: exceeded LoginGraceTime`.
3. Telefon `Connection reset` / `EPERM` hatası alıyor.

İlgili kayıtlar `journalctl -u ssh` içinde, kaynak IP 79.234.222.39 olarak görünüyor.

**Root kilidi doğru bir güvenlik önlemi ve değişmemeli.** Çözüm, izleme için ayrı bir kullanıcı açmak.

## 3. Yapılacaklar

### 3.1 Kullanıcı ve grup

```bash
groupadd --system srvmon
useradd --create-home --shell /bin/bash --gid srvmon srvmon   # komut çalıştırabilmesi için shell gerekli
passwd -l srvmon                                              # şifre yok, kilitli
install -d -m 700 -o srvmon -g srvmon /home/srvmon/.ssh
install -m 600 -o srvmon -g srvmon /dev/null /home/srvmon/.ssh/authorized_keys
```

- `srvmon` kullanıcısı **sudo, docker veya adm gruplarına eklenmemeli.** Docker'a, journal'a ve sisteme agent erişir. Agent root olarak çalışır, ama `srvmon` kullanıcısı sadece agent'ın API'sini kullanabilir.

### 3.2 SSH girişi: sadece key ile

Sunucuda `PasswordAuthentication no` genel olarak açık. **Bu böyle kalmalı.** `srvmon` sadece public key ile girer.

- iPhone uygulaması kendi ed25519 key'ini kendisi üretir. Uygulamada **Settings → This iPhone's SSH key → Copy public key** ile kopyalanır. Satır şöyle görünür:
  `ssh-ed25519 AAAA… server-monitor-ios`
- Bu satır `/home/srvmon/.ssh/authorized_keys` dosyasına eklenir. Birden fazla iPhone olabilir: her cihaz bir satır.

İsteğe bağlı sıkılaştırma. Yeni bir dosya olarak `/etc/ssh/sshd_config.d/40-srvmon.conf`:

```
Match User srvmon
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AllowTcpForwarding no
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    X11Forwarding no
    PermitTunnel no
```

Ardından `sshd -t && systemctl reload ssh`.

**`ForceCommand` kullanma.** Uygulama komutu kendi kabuğu içinde çalıştırır (`{ srvmon-agent api … ; } 2>&1; printf …`), `ForceCommand` bunu bozar.

**Neden şifre değil:** Dashboard'da kullanıcı adı ve şifre göstermek yerine **key yapıştırma alanı** olması daha güvenli. Şifreyle giriş bu sunucuda genel olarak kapalı. Sadece `srvmon` için açmak brute-force riskini geri getirir (fail2ban şu ana kadar 103 IP engellemiş). Şifre seçeneği mutlaka istenirse, yukarıdaki `Match` bloğunda `PasswordAuthentication yes` yapılır, ama önermiyorum.

### 3.3 Agent'ı kurmak (bir kez, root olarak)

**Binary:** Süleyman'ın Mac'inde, uygulamanın içinde duruyor.

| Dosya | sha256 |
|---|---|
| `~/Projects/ServerMonitor/ios/ServerMonitor/Resources/Agent/srvmon-agent-linux-amd64` | `21ad80170b8c0970604d94e9a7c7009e66fe0e9fa056f5db42267c864bfb51ee` |

Süleyman dosyayı yönetim penceresi açıkken sunucuya kopyalar:

```bash
scp ~/Projects/ServerMonitor/ios/ServerMonitor/Resources/Agent/srvmon-agent-linux-amd64 root@217.160.39.208:/tmp/srvmon-agent
```

Sunucuda:

```bash
echo "21ad80170b8c0970604d94e9a7c7009e66fe0e9fa056f5db42267c864bfb51ee  /tmp/srvmon-agent" | sha256sum -c -
install -m 755 /tmp/srvmon-agent /usr/local/bin/srvmon-agent && rm /tmp/srvmon-agent
/usr/local/bin/srvmon-agent version          # 0.3.5 olmalı

install -d -m 700 /etc/srvmon
cat > /etc/srvmon/config.json <<'EOF'
{
  "name": "Romon MCP",
  "socket": "/run/srvmon/agent.sock",
  "socket_group": "srvmon",
  "allow_actions": true
}
EOF
chmod 600 /etc/srvmon/config.json

cat > /etc/systemd/system/srvmon-agent.service <<'EOF'
[Unit]
Description=srvmon agent (server monitor for iOS)
After=network-online.target docker.service
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/srvmon-agent run -config /etc/srvmon/config.json
Restart=always
RestartSec=5
RuntimeDirectory=srvmon
RuntimeDirectoryMode=0750
NoNewPrivileges=true
ProtectSystem=full
PrivateTmp=true
ReadWritePaths=/etc/srvmon

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now srvmon-agent
```

Notlar:
- `socket_group: "srvmon"` ayarı (agent 0.2.1 ve üstü). Socket dosyası `root:srvmon 0660`, klasörü `0750` olur. Sadece root ve `srvmon` grubu erişebilir.
- `allow_actions: true` uygulamada container start/stop/restart butonlarını açar. Sadece izleme isteniyorsa `false` yapılmalı.
- Agent root olarak çalışır, çünkü `/var/run/docker.sock`, `journalctl` ve `systemctl` için root gerekiyor. **Hiç port açmaz.**
- Agent'ın API'sini kullanabilen `srvmon` kullanıcısı şunları yapabilir: container durumlarını ve loglarını okumak, (`allow_actions` açıksa) container'ları başlatıp durdurmak, alarm kurallarını ve push ayarlarını değiştirmek, **agent 0.3.3'ten beri dosya yöneticisiyle dosya okumak, düzenlemek, silmek ve yüklemek** (agent root olduğu için bu işlemler root yetkisiyle yapılır; sistem yolları ve `/etc/srvmon` koruma listesindedir). Kullanıcı kendi shell'inde ise root yetkisi almaz. Bu yüzden iPhone key'inin kimde olduğu önemlidir.
- Unit dosyasında `ProtectHome` **yok**: dosya yöneticisi `/home` ve `/root` altına da yazabilmeli. Uygulamanın kendi kurduğu unit ile aynı.
- Agent 0.3.5, `/var/lib/srvmon/upload` klasörünü `root:srvmon 0770` yapar; uygulamanın SFTP ile `srvmon` olarak gönderdiği dosya oraya yazılır ve agent root olarak yerine taşır.

### 3.4 Dashboard: "Monitoring access" bölümü

Önerilen akış:
1. **Etkinleştir** butonu: Kullanıcıyı, grubu ve agent'ı kurar (3.1–3.3). Agent kuruluysa sadece günceller.
2. **Key ekle** alanı: `ssh-ed25519 … server-monitor-ios` satırı yapıştırılır. Format kontrol edilir (`ssh-keygen -lf` ile). Eklenen key'ler parmak iziyle listelenir ve tek tek silinebilir.
3. **Bağlantı bilgileri kartı.** Kopyalanabilir alanlar:

   | Alan | Değer |
   |---|---|
   | Host | 217.160.39.208 |
   | Port | 22 |
   | User | srvmon |
   | Giriş | iPhone key (şifre yok) |

   Altına bir açıklama: "Server Monitor uygulamasında **+ → Host / Port / User** alanlarını doldur, giriş yöntemi olarak **iPhone key**'i seç, sonra **Connect**'e bas."
4. **Durum:** Agent sürümü, servisin çalışıp çalışmadığı (`systemctl is-active srvmon-agent`), son başarılı `srvmon` girişi (`journalctl -u ssh | grep 'for srvmon'`).
5. **Kapat / kaldır** butonu (bkz. 3.6).

Kurulum asistanında da aynı adım, isteğe bağlı olarak sunulmalı: **"Server Monitor (iOS) erişimini aç"**.

### 3.5 Kabul testleri

```bash
sudo -u srvmon /usr/local/bin/srvmon-agent api GET /v1/health      # HTTP 200, "version":"0.3.5"
sudo -u nobody /usr/local/bin/srvmon-agent api GET /v1/health      # izin hatası (grupta değil)
ls -la /run/srvmon/                                                 # drwxr-x--- root srvmon / srw-rw---- root srvmon agent.sock
sudo -u srvmon sudo -n true                                         # başarısız olmalı (sudo yok)
id srvmon                                                           # docker/sudo/adm grubu YOK
sshd -T -C user=root,host=x,addr=1.2.3.4 | grep authenticationmethods   # root kilidi değişmedi: publickey,keyboard-interactive
```

Son test: iPhone'dan User `srvmon` + iPhone key ile bağlanılır. `journalctl -u ssh` içinde `Accepted publickey for srvmon` görünmeli.

### 3.6 Kaldırma

```bash
systemctl disable --now srvmon-agent
rm -f /etc/systemd/system/srvmon-agent.service /usr/local/bin/srvmon-agent
rm -rf /etc/srvmon /etc/ssh/sshd_config.d/40-srvmon.conf
systemctl daemon-reload && sshd -t && systemctl reload ssh
userdel -r srvmon; groupdel srvmon 2>/dev/null
```

## 4. Yapılmaması gerekenler

- Root kilidine (`30-mcp-root-gate.conf`, `mcp-root-keys`, PAM/TOTP) **dokunma.**
- `PasswordAuthentication`'ı genel olarak açma.
- `srvmon` kullanıcısını `sudo`, `docker` veya `adm` gruplarına ekleme.
- Agent için veya başka bir şey için **port açma.**
- `ForceCommand` kullanma (uygulamanın komut çalıştırma şeklini bozar).
- `PerSourcePenalties` ayarını gevşetme. Sorun yanlış kullanıcıyla girişti, ceza mekanizması doğru çalışıyor.

## 5. İleride

- **Ekip erişimi (relay):** Uygulamanın ekip özelliği için agent, merkezi bir relay'e (`https://monitor.appinsource.eu` gibi) **dışarı doğru** HTTPS ile bağlanır. Bu yine port açmayı gerektirmez. Relay kurulduğunda agent'ın ayarına `relay` bölümü uygulama tarafından eklenecek. Bu brifingin kapsamında değil.
- **Uygulama tarafı (yapıldı, uygulama 0.3.5):** Uygulama `srvmon` gibi root olmayan bir kullanıcıyla bağlandığında kurulum yapmaz; agent'ın bu kullanıcıya cevap verdiğini kontrol edip sunucuyu kaydeder. "Update agent" ve "uninstall" o sunucuda gösterilmez. Sürüm güncellemesi bu sunucuda dashboard veya root üzerinden yapılır: aşağıdaki script yeni binary ile tekrar çalıştırılır, ayar dosyası korunur.

## 6. Tek parça kurulum scripti (3.1 + 3.2 + 3.3 + 3.5)

Aynı script ilk kurulumda ve her agent güncellemesinde kullanılır; var olan kullanıcıya, key'e ve ayar dosyasına dokunmaz.

**Önce, Mac'ten (yönetim penceresi açıkken):**

```bash
scp ~/Projects/ServerMonitor/ios/ServerMonitor/Resources/Agent/srvmon-agent-linux-amd64 root@217.160.39.208:/tmp/srvmon-agent
```

**Sonra sunucuda root olarak.** `IPHONE_KEY` satırına uygulamadaki **Settings → This iPhone's SSH key → Copy key only** çıktısını yapıştır (boş bırakılırsa key adımı atlanır):

```bash
#!/bin/sh
# Server Monitor: root olmayan izleme kullanicisi + agent. Root olarak calistir.
set -eu
IPHONE_KEY=''                      # ornek: ssh-ed25519 AAAA... server-monitor-ios
SHA=21ad80170b8c0970604d94e9a7c7009e66fe0e9fa056f5db42267c864bfb51ee
NAME='Romon MCP'

echo "== 1. kullanici ve grup"
getent group srvmon >/dev/null || groupadd --system srvmon
id srvmon >/dev/null 2>&1 || useradd --create-home --shell /bin/bash --gid srvmon srvmon
passwd -l srvmon >/dev/null
install -d -m 700 -o srvmon -g srvmon /home/srvmon/.ssh
[ -f /home/srvmon/.ssh/authorized_keys ] || install -m 600 -o srvmon -g srvmon /dev/null /home/srvmon/.ssh/authorized_keys
if [ -n "$IPHONE_KEY" ]; then
  grep -qF "$IPHONE_KEY" /home/srvmon/.ssh/authorized_keys || printf '%s\n' "$IPHONE_KEY" >> /home/srvmon/.ssh/authorized_keys
fi

echo "== 2. sshd: srvmon sadece key ile, forwarding yok"
cat > /etc/ssh/sshd_config.d/40-srvmon.conf <<'EOF'
Match User srvmon
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AllowTcpForwarding no
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    X11Forwarding no
    PermitTunnel no
EOF
sshd -t && systemctl reload ssh

echo "== 3. agent"
echo "$SHA  /tmp/srvmon-agent" | sha256sum -c -
install -m 755 /tmp/srvmon-agent /usr/local/bin/srvmon-agent.new
mv -f /usr/local/bin/srvmon-agent.new /usr/local/bin/srvmon-agent
rm -f /tmp/srvmon-agent
install -d -m 700 /etc/srvmon
if [ ! -f /etc/srvmon/config.json ]; then
  cat > /etc/srvmon/config.json <<EOF
{
  "name": "$NAME",
  "socket": "/run/srvmon/agent.sock",
  "socket_group": "srvmon",
  "allow_actions": true
}
EOF
  chmod 600 /etc/srvmon/config.json
fi
cat > /etc/systemd/system/srvmon-agent.service <<'EOF'
[Unit]
Description=srvmon agent (server monitor for iOS)
After=network-online.target docker.service
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/srvmon-agent run -config /etc/srvmon/config.json
Restart=always
RestartSec=5
RuntimeDirectory=srvmon
RuntimeDirectoryMode=0750
NoNewPrivileges=true
ProtectSystem=full
PrivateTmp=true
ReadWritePaths=/etc/srvmon

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable srvmon-agent >/dev/null 2>&1
systemctl restart srvmon-agent
sleep 1

echo "== 4. kontrol"
/usr/local/bin/srvmon-agent version
sudo -u srvmon /usr/local/bin/srvmon-agent api GET /v1/health | head -n1       # HTTP 200 olmali
ls -la /run/srvmon/                                                            # root srvmon, 0750 / 0660
id srvmon                                                                      # docker, sudo, adm YOK
sshd -T -C user=root,host=x,addr=1.2.3.4 | grep -i authenticationmethods       # root kilidi degismedi
echo "OK"
```

Çıktının son satırı `OK` ise iPhone'dan **User `srvmon` + iPhone key** ile eklenebilir. Sonraki agent güncellemelerinde yalnızca `scp` ve script tekrarlanır (SHA satırı yeni binary'nin hash'iyle değiştirilir; güncel hash `ios/ServerMonitor/Resources/Agent/SHA256SUMS` dosyasında).
