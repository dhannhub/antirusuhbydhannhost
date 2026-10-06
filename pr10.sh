#!/bin/bash

REMOTE_PATH="/var/www/pterodactyl/app/Helpers/AntiRusuh.php"

echo "🚀 Memasang Anti Rusuh (toggle di Settings + anti intip server orang lain)..."

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

function ar_patch(string $path, string $marker, callable $fn, string $label, bool $warn = true): void
{
    global $ts;
    if (!is_file($path)) {
        if ($warn) echo "⚠️  $label: file tidak ditemukan, dilewati\n";
        return;
    }
    $src = file_get_contents($path);
    if (strpos($src, $marker) !== false) {
        echo "✔️  $label: sudah terpasang\n";
        return;
    }
    $out = $fn($src);
    if ($out === null || $out === $src) {
        if ($warn) echo "⚠️  $label: pola kode tidak cocok dengan versi panel ini, dilewati\n";
        return;
    }
    copy($path, $path . '.bak_' . $ts);
    file_put_contents($path, $out);
    echo "✅ $label: terpasang\n";
}

// 1) Toggle On/Off di halaman Settings
ar_patch("$panel/resources/views/admin/settings/index.blade.php", 'anti_rusuh', function ($src) {
    $block = <<<'BLADE'
                    <div class="box-body" style="border-top: 1px solid #f4f4f4;">
                        <div class="row">
                            <div class="form-group col-md-4">
                                <label class="control-label">Anti Rusuh</label>
                                <div>
                                    @php($antiRusuhOn = \Pterodactyl\Helpers\AntiRusuh::enabled())
                                    <select name="anti_rusuh" class="form-control">
                                        <option value="true" @if($antiRusuhOn) selected @endif>On</option>
                                        <option value="false" @if(!$antiRusuhOn) selected @endif>Off</option>
                                    </select>
                                    <p class="text-muted"><small>Saat On: hanya Admin ID 1 yang bisa mengelola panel, dan setiap akun hanya bisa melihat server miliknya sendiri.</small></p>
                                </div>
                            </div>
                        </div>
                    </div>

BLADE;
    $pos = strpos($src, '<div class="box-footer">');
    if ($pos === false) return null;
    // mundur ke awal baris supaya indentasi rapi
    $line = strrpos(substr($src, 0, $pos), "\n");
    $pos = $line === false ? $pos : $line + 1;
    return substr($src, 0, $pos) . $block . substr($src, $pos);
}, 'Toggle Anti Rusuh di Settings');

// 2) Simpan toggle saat form Settings disubmit
ar_patch("$panel/app/Http/Controllers/Admin/Settings/IndexController.php", 'AntiRusuh::saveFromRequest', function ($src) {
    $n = 0;
    $out = preg_replace_callback(
        '/\n([ \t]*)(foreach\s*\(\s*\$request->normalize\(\)\s+as\s+\$key\s*=>\s*\$value\s*\)\s*\{)/',
        function ($m) {
            return "\n" . $m[1] . "\\Pterodactyl\\Helpers\\AntiRusuh::saveFromRequest(\$request);\n" . $m[1] . $m[2];
        },
        $src, 1, $n
    );
    return $n ? $out : null;
}, 'Simpan toggle (Settings controller)');

// 3) Admin panel: daftar server hanya milik sendiri + halaman server orang lain ditolak
$files = [];
$serversDir = "$panel/app/Http/Controllers/Admin/Servers";
if (is_dir($serversDir)) {
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($serversDir, FilesystemIterator::SKIP_DOTS));
    foreach ($it as $f) {
        if ($f->isFile() && substr($f->getFilename(), -4) === '.php') $files[] = $f->getPathname();
    }
}
$files[] = "$panel/app/Http/Controllers/Admin/ServersController.php";

foreach ($files as $file) {
    ar_patch($file, 'AntiRusuh', function ($src) {
        $n1 = 0;
        $n2 = 0;
        $out = preg_replace_callback('/(?<![\\\\\w])Server::query\(\)/', function () {
            return '\\Pterodactyl\\Helpers\\AntiRusuh::serverQuery()';
        }, $src, -1, $n1);
        $out = preg_replace_callback(
            '/(public\s+function\s+\w+\s*\([^)]*\bServer\s+\$server\b[^)]*\)\s*(?::\s*[\w\\\\|?]+\s*)?\{)/',
            function ($m) {
                return $m[1] . "\n        \\Pterodactyl\\Helpers\\AntiRusuh::guardServer(\$server);\n";
            },
            $out, -1, $n2
        );
        return ($n1 + $n2) ? $out : null;
    }, 'Admin server: ' . basename($file), false);
}

$listPatched = false;
foreach ($files as $file) {
    if (is_file($file) && strpos(file_get_contents($file), 'AntiRusuh::serverQuery') !== false) $listPatched = true;
}
if (!$listPatched) {
    echo "⚠️  Daftar server di Admin panel tidak ketemu polanya, bagian ini dilewati\n";
}

// 4) Dashboard client: ?type=admin / admin-all dipaksa jadi "owner"
ar_patch("$panel/app/Http/Controllers/Api/Client/ClientController.php", 'AntiRusuh', function ($src) {
    $n = 0;
    $out = preg_replace_callback('/(\$type\s*=\s*\$request->input\(\s*\'type\'\s*\)\s*;)/', function ($m) {
        return $m[1] . "\n        if (\\Pterodactyl\\Helpers\\AntiRusuh::restricts(\$request->user())) {\n            \$type = 'owner';\n        }";
    }, $src, 1, $n);
    return $n ? $out : null;
}, 'Dashboard: hanya server milik sendiri');

// 5) Semua endpoint /api/client/servers/{server}/*: tolak server orang lain
ar_patch("$panel/app/Http/Middleware/Api/Client/Server/AuthenticateServerAccess.php", 'AntiRusuh', function ($src) {
    $n = 0;
    $out = preg_replace_callback('/(\$server\s*=\s*\$request->route\(\)->parameter\(\s*\'server\'\s*\)\s*;)/', function ($m) {
        return $m[1] . "\n\n        if (\$server instanceof \\Pterodactyl\\Models\\Server\n"
            . "            && \\Pterodactyl\\Helpers\\AntiRusuh::restricts(\$request->user())\n"
            . "            && !\\Pterodactyl\\Helpers\\AntiRusuh::owns(\$server, \$request->user())) {\n"
            . "            \\Pterodactyl\\Helpers\\AntiRusuh::deny();\n"
            . "        }";
    }, $src, 1, $n);
    return $n ? $out : null;
}, 'Akses server: tolak server orang lain');
AR_PATCH_EOF

cat > "$AR_TMP/default.php" <<'AR_DEFAULT_EOF'
<?php
try {
    $panel = $argv[1];
    require $panel . '/vendor/autoload.php';
    $app = require $panel . '/bootstrap/app.php';
    $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
    $repo = $app->make(Pterodactyl\Contracts\Repository\SettingsRepositoryInterface::class);
    if ($repo->get('settings::anti_rusuh') === null) {
        $repo->set('settings::anti_rusuh', 'true');
        echo "✅ Anti Rusuh diset default: ON\n";
    } else {
        echo "✔️  Pengaturan Anti Rusuh yang sudah ada dipertahankan\n";
    }
} catch (\Throwable $e) {
    echo "⚠️  Default ON diatur lewat fallback (belum tersimpan di database)\n";
}
AR_DEFAULT_EOF
chmod 644 "$AR_TMP/patch.php" "$AR_TMP/default.php"

"$PHP_BIN" "$AR_TMP/patch.php" "$PANEL_DIR"

# Jalankan perintah panel sebagai user web server supaya file cache/log tidak jadi milik root
WEB_USER="$(stat -c '%U' "$PANEL_DIR/storage" 2>/dev/null || echo root)"
run_as_web() {
  if [ "$WEB_USER" != "root" ] && command -v runuser >/dev/null 2>&1; then
    runuser -u "$WEB_USER" -- "$@"
  else
    "$@"
  fi
}

run_as_web "$PHP_BIN" "$AR_TMP/default.php" "$PANEL_DIR"
(cd "$PANEL_DIR" && run_as_web "$PHP_BIN" artisan view:clear >/dev/null 2>&1) || true

rm -rf "$AR_TMP"

echo "✅ Anti Rusuh berhasil dipasang!"
echo "⚙️  Atur On/Off di Admin -> Settings -> Anti Rusuh (hanya Admin ID 1)"
echo "🔒 Default: ON. Saat ON, tiap akun hanya bisa melihat server miliknya sendiri"
