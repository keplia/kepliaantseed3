# antseed-fleet (v2 - collision-proof)

Jalankan banyak instance Antseed gateway independen di satu VPS, masing-masing
dengan domain sendiri via Cloudflare Tunnel. **Tidak pernah ada tabrakan** nama
tunnel, port, atau hostname - termasuk dengan instance yang sudah dihapus.

## ? Install tercepat - satu perintah

Di VPS (Ubuntu/Debian, root):

```bash
curl -fsSL https://raw.githubusercontent.com/keplia/kepliaantseed3/main/get.sh | sudo bash
```

Script akan menuntun 4 langkah:

1. **Token Cloudflare** - ditempel, tidak ditampilkan di layar.
2. **Domain** - semua domain (zone) di akun kamu dideteksi otomatis, tinggal pilih nomornya.
3. **Nama** - misalnya `api` -> hasilnya `api1.domainmu.com`, `api2.domainmu.com`, dst.
4. **Jumlah** - script mendeteksi spek VPS (CPU, RAM total/tersedia, disk) dan menampilkan tabel rekomendasi yang **menandai baris spek VPS kamu**, plus berapa instance yang masih bisa dibuat **saat ini**. Tinggal masukkan angka (Enter = rekomendasi).

Contoh tampilan:

```
    #    DOMAIN                             STATUS
    1    aitesh.tech                        active
    2    seaku.dev                          active

  Which domain [2]: 2
  Name for the instances (letters, digits, dash) [api]: api
    Domain         seaku.dev
    Name           api
    1st host       https://api1.seaku.dev
    then           https://api2.seaku.dev, https://api3.seaku.dev, ...
```

```
    RAM VPS   BUDGET           FITS      MARK
    2 GB      900 MiB          1
    4 GB      900 MiB          3
    8 GB      900 MiB          7
    16 GB     900 MiB          17        <- this VPS
    32 GB     900 MiB          35
    now       free RAM         11        <- can be created right now
```

Instance yang sudah ada ikut dihitung: nomor nama dilanjutkan otomatis (`api7`, `api8`, ...) dan memori yang sedang terpakai diperhitungkan.

Butuh terminal interaktif (script membaca jawaban dari `/dev/tty`). Kalau tidak ada terminal sama sekali, script berhenti dengan pesan jelas dan memberi perintah yang harus dipakai - tidak pernah lanjut diam-diam tanpa token.

Non-interaktif (cloud-init / CI):

```bash
curl -fsSL https://raw.githubusercontent.com/keplia/kepliaantseed3/main/get.sh \
  | sudo bash -s -- --token 'cf_...' --domain seaku.dev --name api --count 2 --yes
```

Atau clone lalu jalankan:

```bash
git clone https://github.com/keplia/kepliaantseed3 && cd kepliaantseed3
sudo bash install.sh
```

## Isi repository

| File | Fungsi |
|---|---|
| `install.sh` | Installer interaktif (token, pilih domain, nama, rekomendasi jumlah) |
| `antseed-fleet` | CLI manajemen (`list`, `status`, `link`, `logs`, `remove`, `check`, ...) |
| `get.sh` | Pintu masuk satu perintah `curl \| sudo bash` |
| `README.md` | Panduan lengkap |

## Anti-tabrakan (v2)

Tiga lapis proteksi, semuanya **strict** - sekali dipakai, tidak akan pernah
dipakai lagi:

### 1. Port registry permanen
- Semua port yang pernah dialokasikan dicatat di `/etc/antseed-fleet/ports.reserved`.
- Port di registry **tidak akan pernah dipakai ulang**, bahkan setelah instance
  di-`remove`. Ini mencegah skenario "instance baru dapat port milik instance
  lama yang datanya masih ada / wallet masih hidup / service akan dihidupkan lagi".
- Sebelum dipakai, port dicek juga terhadap: listener aktif (`ss`), socket mentah
  (`/proc/net/tcp{,6}`,`udp{,6}`), port yang dideklarasikan unit systemd lain
  (`--port N`), dan `/etc/services`.
- **Range default `20000-40000`** = 20.001 port = **10.000 instance** (gw+buyer).
  Bisa diubah: `ANTSEED_PORT_RANGE_LO` / `ANTSEED_PORT_RANGE_HI`.
- Alokasi pakai *seeded scan*: mulai dari (port tertinggi yang diketahui + 1),
  jadi tetap cepat walau registry sudah punya ribuan entri.

### 2. Tunnel name unik per akun Cloudflare
- Nama tunnel = `<instance>-gateway` (mis. `antseed1-gateway`).
- **Sebelum** dipakai, script mengambil daftar **semua tunnel** di akun Cloudflare
  dan memeriksa bentrok. Kalau nama sudah dipakai tunnel **asing** (bukan milik
  fleet ini) -> otomatis digenerate `<instance>-gateway-2`, `-3`, ... sampai bebas.
- Nama yang dipakai dicatat di `/etc/antseed-fleet/tunnels.reserved`.
- Kalau tunnel itu **milik instance yang sama** (ada `TUNNEL_ID` di state), tetap
  di-reuse supaya `antseed-fleet restore` bekerja normal.

### 3. Hostname / subdomain unik
- Nomor host (`api1`, `api2`, ...) diambil dari max nomor lokal + 1, lalu dicek:
  - ada di `/etc/antseed-fleet/hosts.reserved`? -> skip
  - ada CNAME di zona Cloudflare? -> skip
- Host yang dipakai dicatat permanen di `hosts.reserved`.

### 4. Global lock
- Seluruh operasi create dilindungi `flock` di `/var/lock/antseed-fleet.lock`.
- Dua proses `install.sh` yang jalan bersamaan tidak bisa mendapat port/nama/host
  yang sama - yang kedua menunggu, atau berhenti dengan pesan jelas.

### 5. Dry-run preview - `antseed-fleet check`

Sebelum benar-benar membuat instance, lihat dulu rencana alokasinya:

```bash
sudo CF_API_TOKEN=cf_xxx antseed-fleet check --domain seaku.dev --name api --count 5
```

Output: tabel `SLOT | HOST | GW PORT | BUYER PORT | TUNNEL | CONFLICT`.
Tidak membuat atau mereservasi apapun - murni preview.

## Kelola

```bash
antseed-fleet list              # daftar instance, port, memori, host, tunnel
antseed-fleet status            # health + tes API publik
antseed-fleet link antseed1     # link setup console (1x pakai)
antseed-fleet recover antseed1  # link recovery kalau console sudah diklaim
antseed-fleet keys antseed1 --label laptop
antseed-fleet logs antseed1 -f
antseed-fleet restart|start|stop [NAME]
antseed-fleet restore antseed1  # pulihkan ingress tunnel + DNS jika host 404
antseed-fleet remove antseed1   # hapus service, data disimpan
antseed-fleet remove antseed1 --keys
antseed-fleet check --domain seaku.dev --name api --count 5   # dry-run
antseed-fleet ports             # lihat registry port + pemakaian live
antseed-fleet doctor
```

## Port registry

```bash
antseed-fleet ports
```

Menampilkan jumlah port tereservasi, range yang dipakai, dan tabel instance
dengan status live (`GW_LIVE` / `BUYER_LIVE` = port benar-benar listening).

Sengaja **tidak ada** perintah untuk "lepaskan" port / nama / host dari registry.
Itu by design: nama yang sudah dipakai (wallet masih ada, backup masih ada) atau
port yang pernah dipakai bisa bentrok kalau di-reuse. Kalau benar-benar perlu
reset (misal ganti VPS bersih), hapus file registry secara manual - sadar risiko.

## Troubleshooting: host mengembalikan 404 / hilang

Instance hidup, `/console` jalan, tapi `/v1/...` membalas **404** tanpa header
gateway? Artinya tunnel masih meneruskan ke gateway lain, karena konfigurasi
ingress tunnel tertimpa oleh pembuatan instance lain.

```bash
sudo CF_API_TOKEN=cf_xxx antseed-fleet restore antseed1
```

Perintah ini menulis ulang ingress tunnel dan CNAME DNS ke host yang tercatat
di `/etc/antseed-fleet/<nama>.env`.

## Token Cloudflare

Buat di <https://dash.cloudflare.com/profile/api-tokens> ->
**Create Token** -> **Create Custom Token**:

| Scope | Resource | Level |
|---|---|---|
| Account | Cloudflare Tunnel | Edit |
| Account | Account Settings | Read |
| Zone | DNS | Edit |
| Zone | Zone | Read |

Account Resources: akun kamu * Zone Resources: **All zones from an account**
(supaya semua domain bisa dipilih). Token hanya dipakai saat create dan tidak
disimpan ke disk - boleh di-revoke setelah selesai.

## Rekomendasi kapasitas

900 MiB per instance (buyer ~500 MiB + gateway ~300 MiB), 1 GiB disisakan untuk OS:

| RAM VPS | Instance |
|---|---|
| 1 GB | 1 |
| 2 GB | 1 |
| 3 GB | 2 |
| 4 GB | 3 |
| 6 GB | 5 |
| 8 GB | 7 |
| 12 GB | 12 |
| 16 GB | 17 |
| 24 GB | 26 |
| 32 GB | 35 |
| 48 GB | 53 |
| 64 GB | 71 |

Bisa diubah lewat `ANTSEED_MEM_PER_INSTANCE_MIB` (budget per instance) dan
`ANTSEED_MEM_RESERVE_MIB` (cadangan untuk OS). Disk juga dicek (~400 MiB per
instance).

## Tambah instance lagi

Jalankan perintah yang sama - ia mendeteksi instance yang sudah ada dan
melanjutkan penomoran:

```bash
sudo bash /opt/antseed-fleet/install.sh
```

Untuk menaruh instance baru di domain lain, cukup pilih domain yang berbeda
saat diminta.

## Catatan

- Instance terisolasi penuh (API key, wallet, console, saldo terpisah). Model
  gratis jalan tanpa saldo.
- Setiap instance memakai subdomain sendiri (`api1..`, `api2..`). Satu CNAME per
  instance di Cloudflare.
- Instance installer (`antseed-gateway`/`antseed-buyer`, port 8377/8379) tidak
  pernah disentuh.
- Port dialokasikan otomatis dari range `20000-40000` (bisa diubah), semua
  listen di `127.0.0.1` di belakang tunnel.
- Backup: `/var/lib/antseedN/.antseed/` (wallet) dan `/etc/antseedN/gateway.env`
  (tunnel token).
- `remove` sengaja menyimpan data supaya dana wallet tidak hilang.

## Perubahan v2.0.0

- **Port range** pindah dari `8381+` ke `20000-40000` (scalable sampai ribuan).
  Port yang sudah ada di instalasi lama tetap dipakai apa adanya; hanya instance
  baru yang memakai range baru.
- **Strict registry** (`ports.reserved`, `tunnels.reserved`, `hosts.reserved`).
- **Collision check** tunnel terhadap seluruh akun Cloudflare.
- **Global `flock`** untuk mencegah race condition.
- **`antseed-fleet check`** - dry-run preview alokasi.
- **`antseed-fleet ports`** - lihat registry & status live.
- State file sekarang menyimpan `TUNNEL_NAME` (backward compatible).
