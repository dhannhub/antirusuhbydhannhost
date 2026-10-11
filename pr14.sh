#!/bin/bash

echo "🚀 Memasang Proteksi Kunci Tampilan Sidebar Menu Admin..."

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
# ---------------------------------------------------------------------

AR_TMP="$(mktemp -d)"
chmod 755 "$AR_TMP"

cat > "$AR_TMP/patch.php" <<'AR_PATCH_EOF'
<?php
$panel = $argv[1];
$ts = gmdate('Y-m-d-H-i-s');
$GLOBALS['ar_failed'] = false;

/**
 * Cari blok <li> ... </li> yang mengandung route('$routeName' ...) di sidebar blade.
 * Return [startPos, endPos] (endPos = posisi setelah "</li>") atau null kalau tidak ketemu.
 */
function ar_find_li(string $src, string $routeName): ?array
{
    $pos = strpos($src, "route('" . $routeName . "'");
    if ($pos === false) {
        $pos = strpos($src, 'route("' . $routeName . '"');
    }
    if ($pos === false) {
        return null;
    }

    $before = substr($src, 0, $pos);
    $liStart = strripos($before, '<li');
    if ($liStart === false) {
        return null;
    }

    $liEndTag = stripos($src, '</li>', $pos);
    if ($liEndTag === false) {
        return null;
    }
    $liEnd = $liEndTag + strlen('</li>');

    return [$liStart, $liEnd];
}

$f = "$panel/resources/views/layouts/admin.blade.php";

$items = [
    'admin.api.index'  => ['Application API', 'fa-gamepad'],
    'admin.databases'  => ['Databases',       'fa-database'],
    'admin.locations'  => ['Locations',       'fa-globe'],
    'admin.nodes'      => ['Nodes',           'fa-sitemap'],
    'admin.nests'      => ['Nests',           'fa-th-large'],
    'admin.settings'   => ['Settings',        'fa-wrench'],
];

if (!is_file($f)) {
    echo "⚠️  V14 Kunci Sidebar Menu: file tidak ditemukan ($f)\n";
    $GLOBALS['ar_failed'] = true;
} else {
    $src = file_get_contents($f);
    $orig = $src;
    $anyChanged = false;

    foreach ($items as $route => [$label, $icon]) {
        $marker = "<!-- AR_LOCK:{$route} -->";

        if (strpos($src, $marker) !== false) {
            echo "✔️  V14 Kunci Menu {$label}: sudah terpasang\n";
            continue;
        }

        $bounds = ar_find_li($src, $route);
        if ($bounds === null) {
            echo "⚠️  V14 Kunci Menu {$label}: elemen sidebar tidak ditemukan (pola blade beda)\n";
            $GLOBALS['ar_failed'] = true;
            continue;
        }

        [$start, $end] = $bounds;
        $original = substr($src, $start, $end - $start);

        $replacement = $marker . "\n"
            . "@if(\\Illuminate\\Support\\Facades\\Auth::check() && (int) \\Illuminate\\Support\\Facades\\Auth::user()->id === 1)\n"
            . $original . "\n"
            . "@else\n"
            . "    <li class=\"ar-locked\" style=\"opacity:.45;cursor:not-allowed;\" title=\"Gapunya akses\">\n"
            . "        <a href=\"javascript:void(0)\" onclick=\"return false;\" tabindex=\"-1\" aria-disabled=\"true\">\n"
            . "            <i class=\"fa {$icon}\"></i> <span>{$label} <i class=\"fa fa-lock\" style=\"margin-left:4px;font-size:11px;\"></i></span>\n"
            . "        </a>\n"
            . "    </li>\n"
            . "@endif";

        $src = substr($src, 0, $start) . $replacement . substr($src, $end);
        $anyChanged = true;
        echo "✅ V14 Kunci Menu {$label}: terpasang\n";
    }

    if ($anyChanged) {
        $backup = $f . '.bak_' . $ts;
        if (!is_file($backup)) {
            copy($f, $backup);
        }
        file_put_contents($f, $src);
    }
}

exit($GLOBALS['ar_failed'] ? 4 : 0);
AR_PATCH_EOF
chmod 644 "$AR_TMP/patch.php"

"$PHP_BIN" "$AR_TMP/patch.php" "$PANEL_DIR"
AR_RC=$?
rm -rf "$AR_TMP"

if [ "$AR_RC" -ne 0 ]; then
  echo "❌ Proteksi Kunci Tampilan Sidebar Menu Admin gagal dipasang (kode $AR_RC), cek pesan di atas"
  exit "$AR_RC"
fi

echo "✅ Proteksi Kunci Tampilan Sidebar Menu Admin berhasil dipasang!"
echo "ℹ️  Catatan: ini cuma kunci tampilan sidebar. Blokir akses lewat domain langsung tetap bergantung ke V3/V4/V5/V6/V13 yang sudah terpasang di backend."
