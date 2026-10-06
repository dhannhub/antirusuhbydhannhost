#!/bin/bash

REMOTE_PATH="/var/www/pterodactyl/app/Http/Controllers/Admin/Settings/IndexController.php"
TIMESTAMP=$(date -u +"%Y-%m-%d-%H-%M-%S")
BACKUP_PATH="${REMOTE_PATH}.bak_${TIMESTAMP}"

echo "🚀 Memasang proteksi Anti Akses Settings..."

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

if [ -f "$REMOTE_PATH" ]; then
  mv "$REMOTE_PATH" "$BACKUP_PATH"
  echo "📦 Backup file lama dibuat di $BACKUP_PATH"
fi

mkdir -p "$(dirname "$REMOTE_PATH")"
chmod 755 "$(dirname "$REMOTE_PATH")"

cat > "$REMOTE_PATH" << 'EOF'
<?php

namespace Pterodactyl\Http\Controllers\Admin\Settings;

use Pterodactyl\Helpers\AntiRusuh;
use Illuminate\View\View;
use Illuminate\Http\RedirectResponse;
use Illuminate\Support\Facades\Auth;
use Prologue\Alerts\AlertsMessageBag;
use Illuminate\Contracts\Console\Kernel;
use Illuminate\View\Factory as ViewFactory;
use Pterodactyl\Http\Controllers\Controller;
use Pterodactyl\Traits\Helpers\AvailableLanguages;
use Pterodactyl\Services\Helpers\SoftwareVersionService;
use Pterodactyl\Contracts\Repository\SettingsRepositoryInterface;
use Pterodactyl\Http\Requests\Admin\Settings\BaseSettingsFormRequest;

class IndexController extends Controller
{
    use AvailableLanguages;

    /**
     * IndexController constructor.
     */
    public function __construct(
        private AlertsMessageBag $alert,
        private Kernel $kernel,
        private SettingsRepositoryInterface $settings,
        private SoftwareVersionService $versionService,
        private ViewFactory $view
    ) {
    }

    /**
     * Render the UI for basic Panel settings.
     */
    public function index(): View
    {
        // 🔒 Anti akses menu Settings selain user ID 1
        $user = Auth::user();
        if (!$user || $user->id !== 1) {
            abort(403, 'Dilarang Rusuh disini ');
        }

        return $this->view->make('admin.settings.index', [
            'version' => $this->versionService,
            'languages' => $this->getAvailableLanguages(true),
        ]);
    }

    /**
     * Handle settings update.
     *
     * @throws \Pterodactyl\Exceptions\Model\DataValidationException
     * @throws \Pterodactyl\Exceptions\Repository\RecordNotFoundException
     */
    public function update(BaseSettingsFormRequest $request): RedirectResponse
    {
        // 🔒 Anti akses update settings selain user ID 1
        $user = Auth::user();
        if (!$user || $user->id !== 1) {
            abort(403, 'BOCAH TOLOL NGINTIP NGINTIP ');
        }

        // Simpan toggle Anti Rusuh (hanya Admin ID 1)
        AntiRusuh::saveFromRequest($request);

        foreach ($request->normalize() as $key => $value) {
            $this->settings->set('settings::' . $key, $value);
        }

        $this->kernel->call('queue:restart');
        $this->alert->success(
            'Panel settings have been updated successfully and the queue worker was restarted to apply these changes.'
        )->flash();

        return redirect()->route('admin.settings');
    }
}
EOF

chmod 644 "$REMOTE_PATH"

echo "✅ Proteksi Anti Akses Settings berhasil dipasang!"
echo "📂 Lokasi file: $REMOTE_PATH"
echo "🗂️ Backup file lama: $BACKUP_PATH (jika sebelumnya ada)"
echo "🔒 Hanya Admin (ID 1) yang bisa Akses Settings."
