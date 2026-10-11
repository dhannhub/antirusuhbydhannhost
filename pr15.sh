#!/bin/bash

echo "🚀 Memasang Proteksi Batasi Pencarian Owner (Server Owner & Users)..."

PHP_BIN="$(command -v php)"
if [ -z "$PHP_BIN" ]; then
  echo "❌ php tidak ditemukan di server panel"
  exit 1
fi

if [ ! -d "/var/www/pterodactyl/app" ]; then
  echo "❌ Panel Pterodactyl tidak ditemukan di /var/www/pterodactyl"
  exit 1
fi

PANEL_DIR="/var/www/pterodactyl"

# --- Anti Rusuh helper inti (dipakai semua proteksi, dipasang otomatis) ---
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

class AntiRusuh
{
    public const SETTING_KEY = 'settings::anti_rusuh';
    public const MESSAGE = 'Gapunya akses';

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

    public static function serverQuery()
    {
        $query = Server::query();

        if (self::restricts()) {
            $user = Auth::user();
            $query->where('servers.owner_id', $user ? $user->id : 0);
        }

        return $query;
    }

    public static function guardServer(Server $server): void
    {
        if (!self::restricts() || self::owns($server)) {
            return;
        }

        self::deny();
    }

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

    public static function abortUnlessSuper(string $message = 'Akses ditolak'): void
    {
        if (self::restricts()) {
            abort(403, trim($message));
        }
    }

    public static function abortUnlessSuperAlways(string $message = 'Akses ditolak'): void
    {
        if (!self::isSuperAdmin()) {
            abort(403, trim($message));
        }
    }

    public static function denyUnlessSuper(string $message): void
    {
        if (self::restricts()) {
            throw new DisplayException(trim($message));
        }
    }

    public static function guardDelete(Server $server): void
    {
        if (!self::enabled()) {
            return;
        }

        $user = Auth::user();
        if (!$user || (int) $user->id === 1) {
            return;
        }

        if ((int) $server->owner_id !== (int) $user->id) {
            throw new DisplayException('Anti Delete Server');
        }
    }

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

# --- Anti Rusuh Owner helper (khusus fitur V15: catat & batasi pencarian owner) ---
AR_OWNER_HELPER="$PANEL_DIR/app/Helpers/AntiRusuhOwner.php"
cat > "$AR_OWNER_HELPER" <<'AR_OWNER_HELPER_EOF'
<?php

namespace Pterodactyl\Helpers;

use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Schema;
use Pterodactyl\Models\User;

/**
 * V15: catat siapa yang membuat sebuah user (created_by), dan batasi
 * pencarian owner (dipakai di New Server & halaman Users) supaya admin
 * non-ID-1 cuma menemukan akunnya sendiri + user yang dia buat.
 */
class AntiRusuhOwner
{
    protected static function columnReady(): bool
    {
        try {
            return Schema::hasColumn('users', 'created_by');
        } catch (\Throwable $e) {
            return false;
        }
    }

    public static function trackCreatedBy(User $user): void
    {
        if (!self::columnReady()) {
            return;
        }

        $creator = Auth::id();
        if (!$creator) {
            return;
        }

        $user->forceFill(['created_by' => $creator])->saveQuietly();
    }

    /**
     * Dipanggil di dalam closure ->where(function ($q) { ... }) pada query listing.
     */
    public static function restrictUserQuery($query): void
    {
        if (AntiRusuh::isSuperAdmin() || !self::columnReady()) {
            return;
        }

        $id = Auth::id();
        $query->where('users.id', $id)->orWhere('users.created_by', $id);
    }

    /**
     * Pengganti User::query()->findOrFail($id) supaya lookup satu user juga dibatasi.
     */
    public static function restrictSingleUser($id): User
    {
        $query = User::query();

        if (!AntiRusuh::isSuperAdmin() && self::columnReady()) {
            $userId = Auth::id();
            $query->where(function ($q) use ($userId) {
                $q->where('id', $userId)->orWhere('created_by', $userId);
            });
        }

        return $query->findOrFail($id);
    }
}
AR_OWNER_HELPER_EOF
chmod 644 "$AR_OWNER_HELPER"
# ---------------------------------------------------------------------

AR_TMP="$(mktemp -d)"
chmod 755 "$AR_TMP"

# --- Tahap 1: migrasi kolom created_by (butuh bootstrap Laravel penuh) ---
cat > "$AR_TMP/setup.php" <<'AR_SETUP_EOF'
<?php
try {
    $panel = $argv[1];
    require $panel . '/vendor/autoload.php';
    $app = require $panel . '/bootstrap/app.php';
    $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

    if (!\Illuminate\Support\Facades\Schema::hasColumn('users', 'created_by')) {
        \Illuminate\Support\Facades\Schema::table('users', function ($table) {
            $table->unsignedInteger('created_by')->nullable()->after('root_admin');
        });
        echo "✅ Kolom created_by ditambahkan ke tabel users\n";
    } else {
        echo "✔️  Kolom created_by sudah ada\n";
    }
    exit(0);
} catch (\Throwable $e) {
    echo "❌ Setup database gagal: " . $e->getMessage() . "\n";
    exit(6);
}
AR_SETUP_EOF
chmod 644 "$AR_TMP/setup.php"

WEB_USER="$(stat -c '%U' "$PANEL_DIR/storage" 2>/dev/null || echo root)"
run_as_web() {
  if [ "$WEB_USER" != "root" ] && command -v runuser >/dev/null 2>&1; then
    runuser -u "$WEB_USER" -- "$@"
  else
    "$@"
  fi
}

if ! run_as_web "$PHP_BIN" "$AR_TMP/setup.php" "$PANEL_DIR"; then
  rm -rf "$AR_TMP"
  echo "❌ Proteksi Batasi Pencarian Owner gagal dipasang (migrasi kolom gagal)"
  exit 6
fi

# --- Tahap 2: patch UserController.php (text-only, cepat) ---
cat > "$AR_TMP/patch.php" <<'AR_PATCH_EOF'
<?php
$panel = $argv[1];
$ts = gmdate('Y-m-d-H-i-s');
$GLOBALS['ar_failed'] = false;

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

$f = "$panel/app/Http/Controllers/Admin/UserController.php";

// 1) Catat pembuat user saat admin non-ID-1 membuat user baru lewat Admin -> Users -> New
ar_patch($f, 'AntiRusuhOwner::trackCreatedBy', function ($src) {
    $needle = '$user = $this->creationService->handle($request->normalize());';
    $pos = strpos($src, $needle);
    if ($pos === false) {
        return null;
    }
    $insertPos = $pos + strlen($needle);
    $insert = "\n\n        \\Pterodactyl\\Helpers\\AntiRusuhOwner::trackCreatedBy(\$user);";

    return substr($src, 0, $insertPos) . $insert . substr($src, $insertPos);
}, 'V15 Catat Pembuat User');

// 2) Batasi daftar hasil pencarian owner (dipakai select2 New Server & halaman Users)
ar_patch($f, 'AntiRusuhOwner::restrictUserQuery', function ($src) {
    $needle = 'QueryBuilder::for(User::query())';
    $pos = strpos($src, $needle);
    if ($pos === false) {
        return null;
    }
    $paginatePos = strpos($src, '->paginate(', $pos);
    if ($paginatePos === false) {
        return null;
    }
    $insert = "->where(function (\$q) {\n                \\Pterodactyl\\Helpers\\AntiRusuhOwner::restrictUserQuery(\$q);\n            })\n            ";

    return substr($src, 0, $paginatePos) . $insert . substr($src, $paginatePos);
}, 'V15 Batasi Daftar Owner');

// 3) Batasi lookup owner tunggal (saat select2 resolve 1 user_id)
ar_patch($f, 'AntiRusuhOwner::restrictSingleUser', function ($src) {
    $needle = "User::query()->findOrFail(\$request->input('user_id'));";
    $pos = strpos($src, $needle);
    if ($pos === false) {
        return null;
    }
    $replacement = "\\Pterodactyl\\Helpers\\AntiRusuhOwner::restrictSingleUser(\$request->input('user_id'));";

    return substr($src, 0, $pos) . $replacement . substr($src, $pos + strlen($needle));
}, 'V15 Batasi Lookup Owner Tunggal');

exit($GLOBALS['ar_failed'] ? 4 : 0);
AR_PATCH_EOF
chmod 644 "$AR_TMP/patch.php"

"$PHP_BIN" "$AR_TMP/patch.php" "$PANEL_DIR"
AR_RC=$?
rm -rf "$AR_TMP"

if [ "$AR_RC" -ne 0 ]; then
  echo "❌ Proteksi Batasi Pencarian Owner gagal dipasang (kode $AR_RC), cek pesan di atas"
  exit "$AR_RC"
fi

echo "✅ Proteksi Batasi Pencarian Owner berhasil dipasang!"
echo "ℹ️  Admin ID 1 tetap lihat semua user. Admin lain cuma nemu akunnya sendiri + user yang dia buat lewat Admin -> Users -> New."
echo "ℹ️  User yang sudah ada SEBELUM script ini dipasang belum punya catatan 'dibuat oleh', jadi cuma akan muncul buat Admin ID 1 sampai dibuat ulang/di-assign manual."
