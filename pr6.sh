#!/bin/bash

echo "🚀 Memasang Proteksi Anti Akses Settings..."

PHP_BIN="$(command -v php)"
if [ -z "$PHP_BIN" ]; then
  echo "❌ php tidak ditemukan di server panel"
  exit 1
fi

if [ ! -d "/var/www/pterodactyl/app" ]; then
  echo "❌ Panel Pterodactyl tidak ditemukan di /var/www/pterodactyl"
  exit 1
fi

# --- Anti Rusuh helper (dipakai semua proteksi, dipasang otomatis) ---
PANEL_DIR="/var/www/pterodactyl"
AR_HELPER="$PANEL_DIR/app/Helpers/AntiRusuh.php"
mkdir -p "$(dirname "$AR_HELPER")"
cat > "$AR_HELPER" <<'AR_HELPER_EOF'
<?php

namespace Pterodactyl\Helpers;

use Illuminate\Http\Exceptions\HttpResponseException;
use Illuminate\Support\Facades\Auth;
use Prologue\Alerts\AlertsMessageBag;
use Pterodactyl\Contracts\Repository\SettingsRepositoryInterface;
use Pterodactyl\Exceptions\DisplayException;
use Pterodactyl\Models\Server;

/**
 * Anti Rusuh helper.
 * Satu sumber kebenaran untuk status ON/OFF (Admin -> Settings) dan aturan kepemilikan server.
 */
class AntiRusuh
{
    public const SETTING_KEY = 'settings::anti_rusuh';
    public const MESSAGE = 'Gapunya akses';

    /**
     * Anti Rusuh aktif? Default ON kalau belum pernah diatur.
     */
    public static function enabled(): bool
    {
        try {
            $value = app(SettingsRepositoryInterface::class)->get(self::SETTING_KEY, 'true');
        } catch (\Throwable $e) {
            return true;
        }

        return !in_array(strtolower(trim((string) $value)), ['false', '0', 'off', 'no'], true);
    }

    public static function isSuperAdmin($user = null): bool
    {
        $user = $user ?? Auth::user();

        return $user && (int) $user->id === 1;
    }

    /**
     * True kalau pembatasan berlaku untuk user ini (Anti Rusuh ON dan bukan Admin ID 1).
     */
    public static function restricts($user = null): bool
    {
        $user = $user ?? Auth::user();

        return self::enabled() && !self::isSuperAdmin($user);
    }

    public static function owns(Server $server, $user = null): bool
    {
        $user = $user ?? Auth::user();

        return $user && (int) $server->owner_id === (int) $user->id;
    }

    /**
     * Query server yang sudah dibatasi: user biasa/admin non-ID-1 hanya melihat server miliknya.
     */
    public static function serverQuery()
    {
        $query = Server::query();

        if (self::restricts()) {
            $user = Auth::user();
            $query->where('servers.owner_id', $user ? $user->id : 0);
        }

        return $query;
    }

    /**
     * Tolak akses ke server milik orang lain.
     */
    public static function guardServer(Server $server): void
    {
        if (!self::restricts() || self::owns($server)) {
            return;
        }

        self::deny();
    }

    /**
     * API/JSON -> 403 dengan pesan. Halaman admin -> kembali ke daftar server + alert.
     */
    public static function deny(?string $message = null): void
    {
        $message = $message ?: self::MESSAGE;
        $request = request();

        if ($request->expectsJson() || $request->is('api/*')) {
            abort(403, $message);
        }

        app(AlertsMessageBag::class)->danger($message)->flash();

        throw new HttpResponseException(redirect('/admin/servers'));
    }

    /**
     * 403 untuk semua kecuali Admin ID 1 (hanya berlaku saat Anti Rusuh ON).
     */
    public static function abortUnlessSuper(string $message = 'Akses ditolak'): void
    {
        if (self::restricts()) {
            abort(403, trim($message));
        }
    }

    /**
     * Sama seperti di atas tapi SELALU berlaku (dipakai untuk halaman Settings).
     */
    public static function abortUnlessSuperAlways(string $message = 'Akses ditolak'): void
    {
        if (!self::isSuperAdmin()) {
            abort(403, trim($message));
        }
    }

    /**
     * Alert merah + kembali ke halaman sebelumnya, hanya saat Anti Rusuh ON.
     */
    public static function denyUnlessSuper(string $message): void
    {
        if (self::restricts()) {
            throw new DisplayException(trim($message));
        }
    }

    /**
     * Hapus server: hanya Admin ID 1 atau pemilik server.
     */
    public static function guardDelete(Server $server): void
    {
        if (!self::enabled()) {
            return;
        }

        $user = Auth::user();
        if (!$user || (int) $user->id === 1) {
            return; // CLI / background job tetap jalan
        }

        if ((int) $server->owner_id !== (int) $user->id) {
            throw new DisplayException('Anti Delete Server');
        }
    }

    /**
     * Simpan nilai toggle dari form Settings. Hanya Admin ID 1 yang boleh mengubah.
     */
    public static function saveFromRequest($request): void
    {
        if (!$request->has('anti_rusuh') || !self::isSuperAdmin()) {
            return;
        }

        app(SettingsRepositoryInterface::class)->set(
            self::SETTING_KEY,
            $request->input('anti_rusuh') === 'true' ? 'true' : 'false'
        );
    }
}
AR_HELPER_EOF
chmod 644 "$AR_HELPER"
# ---------------------------------------------------------------------

AR_TMP="$(mktemp -d)"
chmod 755 "$AR_TMP"

cat > "$AR_TMP/patch.php" <<'AR_PATCH_EOF'
<?php
$panel = $argv[1];
$ts = gmdate('Y-m-d-H-i-s');
$GLOBALS['ar_failed'] = false;

function ar_has(string $text, array $sigs): bool
{
    foreach ($sigs as $s) {
        if (strpos($text, $s) !== false) {
            return true;
        }
    }
    return false;
}

// Kalau file hasil "timpa penuh" versi lama terdeteksi, kembalikan dulu file asli dari backup tertua yang bersih.
function ar_restore_legacy(string $path, array $sigs): void
{
    global $ts;
    if (!is_file($path) || !ar_has(file_get_contents($path), $sigs)) {
        return;
    }
    $backups = glob($path . '.bak_*') ?: [];
    sort($backups);
    foreach ($backups as $b) {
        if (!ar_has(file_get_contents($b), $sigs)) {
            copy($path, $path . '.legacy_' . $ts);
            copy($b, $path);
            echo "♻️  " . basename($path) . ": versi timpa-penuh lama dikembalikan ke file asli\n";
            return;
        }
    }
    echo "⚠️  " . basename($path) . ": terdeteksi versi lama tapi backup asli tidak ditemukan\n";
    $GLOBALS['ar_failed'] = true;
}

function ar_patch(string $path, string $marker, callable $fn, string $label): void
{
    global $ts;
    if (!is_file($path)) {
        echo "⚠️  $label: file tidak ditemukan ($path)\n";
        $GLOBALS['ar_failed'] = true;
        return;
    }
    $src = file_get_contents($path);
    if (strpos($src, $marker) !== false) {
        echo "✔️  $label: sudah terpasang\n";
        return;
    }
    $out = $fn($src);
    if ($out === null || $out === $src) {
        echo "⚠️  $label: pola kode tidak cocok dengan versi panel ini\n";
        $GLOBALS['ar_failed'] = true;
        return;
    }
    $backup = $path . '.bak_' . $ts;
    if (!is_file($backup)) {
        copy($path, $backup);
    }
    file_put_contents($path, $out);
    $lint = [];
    exec(escapeshellarg(PHP_BINARY) . ' -l ' . escapeshellarg($path) . ' 2>&1', $lint, $rc);
    if ($rc !== 0) {
        file_put_contents($path, $src);
        echo "❌ $label: hasil patch error sintaks, dibatalkan (file dikembalikan)\n";
        $GLOBALS['ar_failed'] = true;
        return;
    }
    echo "✅ $label: terpasang\n";
}

// Sisipkan $code tepat setelah "{" pembuka method public yang namanya cocok.
function ar_inject_methods(string $src, string $namePattern, string $code, string $paramNeedle = ''): array
{
    $count = 0;
    $out = preg_replace_callback(
        '/(public\s+function\s+(' . $namePattern . ')\s*\(([^)]*)\)\s*(?::\s*[\w\\\\|?]+\s*)?\{)/',
        function ($m) use (&$count, $code, $paramNeedle) {
            if ($m[2] === '__construct') {
                return $m[1];
            }
            if ($paramNeedle !== '' && strpos($m[3], $paramNeedle) === false) {
                return $m[1];
            }
            $count++;
            return $m[1] . "\n        " . $code;
        },
        $src
    );
    return [$out, $count];
}


$f = "$panel/app/Http/Controllers/Admin/Settings/IndexController.php";
ar_restore_legacy($f, ['Anti akses menu Settings selain user ID 1', 'Anti akses update settings']);
// Settings SELALU hanya untuk Admin ID 1 (supaya toggle Anti Rusuh tidak bisa diubah orang lain)
ar_patch($f, 'AntiRusuh::abortUnlessSuperAlways', function ($src) {
    [$out, $n] = ar_inject_methods($src, '\w+', "\\Pterodactyl\\Helpers\\AntiRusuh::abortUnlessSuperAlways('Dilarang Rusuh disini');");
    return $n ? $out : null;
}, 'V6 Anti Akses Settings');
// Simpan toggle On/Off saat form Settings disubmit
ar_patch($f, 'AntiRusuh::saveFromRequest', function ($src) {
    $n = 0;
    $out = preg_replace_callback(
        '/\n([ \t]*)(foreach\s*\(\s*\$request->normalize\(\)\s+as\s+\$key\s*=>\s*\$value\s*\)\s*\{)/',
        function ($m) {
            return "\n" . $m[1] . "\\Pterodactyl\\Helpers\\AntiRusuh::saveFromRequest(\$request);\n" . $m[1] . $m[2];
        },
        $src, 1, $n
    );
    return $n ? $out : null;
}, 'V6 Simpan toggle Anti Rusuh');

exit($GLOBALS['ar_failed'] ? 4 : 0);
AR_PATCH_EOF
chmod 644 "$AR_TMP/patch.php"

"$PHP_BIN" "$AR_TMP/patch.php" "$PANEL_DIR"
AR_RC=$?
rm -rf "$AR_TMP"

if [ "$AR_RC" -ne 0 ]; then
  echo "❌ Proteksi Anti Akses Settings gagal dipasang (kode $AR_RC), cek pesan di atas"
  exit "$AR_RC"
fi

echo "✅ Proteksi Anti Akses Settings berhasil dipasang!"
echo "⚙️  Ikut toggle Anti Rusuh (Admin -> Settings), default ON"
