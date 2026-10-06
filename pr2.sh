#!/bin/bash

REMOTE_PATH="/var/www/pterodactyl/app/Http/Controllers/Admin/UserController.php"
TIMESTAMP=$(date -u +"%Y-%m-%d-%H-%M-%S")
BACKUP_PATH="${REMOTE_PATH}.bak_${TIMESTAMP}"

echo "🚀 Memasang proteksi UserController.php anti hapus dan anti ubah data user..."

# Backup file lama jika ada
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

cat > "$REMOTE_PATH" <<'EOF'
<?php

namespace Pterodactyl\Http\Controllers\Admin;

use Pterodactyl\Helpers\AntiRusuh;
use Illuminate\View\View;
use Illuminate\Http\Request;
use Pterodactyl\Models\User;
use Pterodactyl\Models\Model;
use Illuminate\Support\Collection;
use Illuminate\Http\RedirectResponse;
use Prologue\Alerts\AlertsMessageBag;
use Spatie\QueryBuilder\QueryBuilder;
use Illuminate\View\Factory as ViewFactory;
use Pterodactyl\Exceptions\DisplayException;
use Pterodactyl\Http\Controllers\Controller;
use Illuminate\Contracts\Translation\Translator;
use Pterodactyl\Services\Users\UserUpdateService;
use Pterodactyl\Traits\Helpers\AvailableLanguages;
use Pterodactyl\Services\Users\UserCreationService;
use Pterodactyl\Services\Users\UserDeletionService;
use Pterodactyl\Http\Requests\Admin\UserFormRequest;
use Pterodactyl\Http\Requests\Admin\NewUserFormRequest;
use Pterodactyl\Contracts\Repository\UserRepositoryInterface;
class UserController extends Controller
{
    use AvailableLanguages;

    /**
     * UserController constructor.
     */
    public function __construct(
        protected AlertsMessageBag $alert,
        protected UserCreationService $creationService,
        protected UserDeletionService $deletionService,
        protected Translator $translator,
        protected UserUpdateService $updateService,
        protected UserRepositoryInterface $repository,
        protected ViewFactory $view
    ) {
    }

    /**
     * Display user index page.
     */
    public function index(Request $request): View
    {
        $users = QueryBuilder::for(
            User::query()->select('users.*')
                ->selectRaw('COUNT(DISTINCT(subusers.id)) as subuser_of_count')
                ->selectRaw('COUNT(DISTINCT(servers.id)) as servers_count')
                ->leftJoin('subusers', 'subusers.user_id', '=', 'users.id')
                ->leftJoin('servers', 'servers.owner_id', '=', 'users.id')
                ->groupBy('users.id')
        )
            ->allowedFilters(['username', 'email', 'uuid'])
            ->allowedSorts(['id', 'uuid'])
            ->paginate(50);

        return $this->view->make('admin.users.index', ['users' => $users]);
    }

    /**
     * Display new user page.
     */
    public function create(): View
    {
        return $this->view->make('admin.users.new', [
            'languages' => $this->getAvailableLanguages(true),
        ]);
    }

    /**
     * Display user view page.
     */
    public function view(User $user): View
    {
        return $this->view->make('admin.users.view', [
            'user' => $user,
            'languages' => $this->getAvailableLanguages(true),
        ]);
    }

    /**
     * Delete a user from the system.
     *
     * @throws Exception
     * @throws PterodactylExceptionsDisplayException
     */
    public function delete(Request $request, User $user): RedirectResponse
    {
        // === FITUR TAMBAHAN: Proteksi hapus user ===
        if (AntiRusuh::enabled() && $request->user()->id !== 1) {
            throw new DisplayException(" Jangan hapus akun orang ");
        }
        // ============================================

        if ($request->user()->id === $user->id) {
            throw new DisplayException($this->translator->get('admin/user.exceptions.user_has_servers'));
        }

        $this->deletionService->handle($user);

        return redirect()->route('admin.users');
    }

    /**
     * Create a user.
     *
     * @throws Exception
     * @throws Throwable
     */
    public function store(NewUserFormRequest $request): RedirectResponse
    {
        $user = $this->creationService->handle($request->normalize());
        $this->alert->success($this->translator->get('admin/user.notices.account_created'))->flash();

        return redirect()->route('admin.users.view', $user->id);
    }

    /**
     * Update a user on the system.
     *
     * @throws PterodactylExceptionsModelDataValidationException
     * @throws PterodactylExceptionsRepositoryRecordNotFoundException
     */
    public function update(UserFormRequest $request, User $user): RedirectResponse
    {
        // === FITUR TAMBAHAN: Proteksi ubah data penting ===
        $restrictedFields = ['email', 'first_name', 'last_name', 'password'];

        foreach ($restrictedFields as $field) {
            if (AntiRusuh::enabled() && $request->filled($field) && $request->user()->id !== 1) {
                throw new DisplayException("⚠️ Data hanya bisa diubah oleh admin ID 1.");
            }
        }

        // Cegah turunkan level admin ke user biasa
        if (AntiRusuh::enabled() && $user->root_admin && $request->user()->id !== 1) {
            throw new DisplayException("🚫 Tidak dapat menurunkan hak admin pengguna ini. Hanya ID 1 yang memiliki izin.");
        }
        // ====================================================

        $this->updateService
            ->setUserLevel(User::USER_LEVEL_ADMIN)
            ->handle($user, $request->normalize());

        $this->alert->success(trans('admin/user.notices.account_updated'))->flash();

        return redirect()->route('admin.users.view', $user->id);
    }

    /**
     * Get a JSON response of users on the system.
     */
    public function json(Request $request): Model|Collection
    {
        $users = QueryBuilder::for(User::query())->allowedFilters(['email'])->paginate(25);

        // Handle single user requests.
        if ($request->query('user_id')) {
            $user = User::query()->findOrFail($request->input('user_id'));
            $user->md5 = md5(strtolower($user->email));

            return $user;
        }

        return $users->map(function ($item) {
            $item->md5 = md5(strtolower($item->email));

            return $item;
        });
    }
}
EOF

chmod 644 "$REMOTE_PATH"
echo "✅ Proteksi UserController.php berhasil dipasang!"
echo "📂 Lokasi file: $REMOTE_PATH"
echo "🗂️ Backup file lama: $BACKUP_PATH"
