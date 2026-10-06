#!/bin/bash

echo "🚀 Memasang Support Report & Ide..."

PHP_BIN="$(command -v php)"
if [ -z "$PHP_BIN" ]; then
  echo "❌ php tidak ditemukan di server panel"
  exit 1
fi

PANEL_DIR="/var/www/pterodactyl"
if [ ! -d "$PANEL_DIR/app" ]; then
  echo "❌ Panel Pterodactyl tidak ditemukan di $PANEL_DIR"
  exit 1
fi

# --- 1) tulis file baru (tidak menimpa file bawaan panel) ---
mkdir -p "$(dirname "$PANEL_DIR/app/Helpers/AntiRusuhLog.php")"
cat > "$PANEL_DIR/app/Helpers/AntiRusuhLog.php" <<'AR_F1_EOF'
<?php

namespace Pterodactyl\Helpers;

use Illuminate\Auth\Events\Failed;
use Illuminate\Auth\Events\Login;
use Illuminate\Auth\Events\Logout;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Event;
use Illuminate\Support\Facades\Schema;
use Pterodactyl\Contracts\Repository\SettingsRepositoryInterface;

/**
 * Anti Rusuh: log aktivitas semua user (V11) dan support/report/ide (V12).
 * Semua data disimpan sebagai snapshot teks (tanpa foreign key), jadi user yang sudah dihapus tetap terbaca namanya.
 */
class AntiRusuhLog
{
    public const RETENTION_DAYS = 30;
    public const TABLE_LOGS = 'anti_rusuh_logs';
    public const TABLE_SUPPORT = 'anti_rusuh_support';

    private static bool $booted = false;

    // ------------------------------------------------------------------ settings

    public static function setting(string $key, $default = null)
    {
        try {
            $value = app(SettingsRepositoryInterface::class)->get('settings::' . $key, $default);

            return $value ?? $default;
        } catch (\Throwable $e) {
            return $default;
        }
    }

    public static function setSetting(string $key, string $value): void
    {
        app(SettingsRepositoryInterface::class)->set('settings::' . $key, $value);
    }

    public static function flag(string $name): bool
    {
        try {
            return (bool) Cache::remember('anti_rusuh:flag:' . $name, 30, function () use ($name) {
                return self::setting('anti_rusuh_feature_' . $name, 'false') === 'true';
            });
        } catch (\Throwable $e) {
            return self::setting('anti_rusuh_feature_' . $name, 'false') === 'true';
        }
    }

    /** Cooldown log (detik). 0 = semua aksi dicatat. */
    public static function cooldown(): int
    {
        return max(0, min(3600, (int) self::setting('anti_rusuh_log_cooldown', 5)));
    }

    // ------------------------------------------------------------------ boot

    public static function boot(): void
    {
        try {
            if (self::$booted || app()->runningInConsole()) {
                return;
            }
            self::$booted = true;

            if (!self::flag('logs')) {
                return;
            }

            try {
                app(\Illuminate\Contracts\Http\Kernel::class)->pushMiddleware(\Pterodactyl\Http\Middleware\AntiRusuhLogger::class);
            } catch (\Throwable $e) {
                foreach (['web', 'client-api', 'application-api'] as $group) {
                    try {
                        app('router')->pushMiddlewareToGroup($group, \Pterodactyl\Http\Middleware\AntiRusuhLogger::class);
                    } catch (\Throwable $e2) {
                        // grup tidak ada di versi panel ini
                    }
                }
            }

            Event::listen(Login::class, function ($event) {
                self::onLogin($event);
            });
            Event::listen(Logout::class, function ($event) {
                self::onLogout($event);
            });
            Event::listen(Failed::class, function ($event) {
                self::onFailed($event);
            });
        } catch (\Throwable $e) {
            // log tidak boleh merusak panel
        }
    }

    // ------------------------------------------------------------------ helpers

    public static function ip(): string
    {
        try {
            return (string) request()->ip();
        } catch (\Throwable $e) {
            return '';
        }
    }

    public static function clean($value, int $max = 150): string
    {
        if (is_array($value)) {
            $value = implode(',', array_slice(array_map('strval', array_filter($value, 'is_scalar')), 0, 5));
        }
        $value = preg_replace('/[\x00-\x1F\x7F]+/u', ' ', (string) $value) ?? '';

        return mb_substr(trim($value), 0, $max);
    }

    private static function actor($user): array
    {
        return [
            'actor_id' => isset($user->id) ? (int) $user->id : null,
            'actor_name' => self::clean($user->username ?? '?', 191),
            'actor_email' => self::clean($user->email ?? '', 191),
            'actor_admin' => !empty($user->root_admin) ? 1 : 0,
        ];
    }

    private static function base(string $action, string $label, string $target = '', string $detail = '', int $status = 200): array
    {
        $req = request();

        return [
            'action' => $action,
            'label' => $label,
            'target' => $target,
            'detail' => $detail,
            'ip' => self::ip(),
            'method' => strtoupper((string) $req->method()),
            'path' => '/' . ltrim((string) $req->path(), '/'),
            'status' => $status,
        ];
    }

    // ------------------------------------------------------------------ auth events

    private static function onLogin($event): void
    {
        try {
            // Login yang dipicu oleh API key (bukan login manusia) tidak dicatat
            if (str_starts_with(trim((string) request()->path(), '/'), 'api/')) {
                return;
            }
            self::record(array_merge(self::actor($event->user), self::base('auth.login', 'Login berhasil')));
        } catch (\Throwable $e) {
        }
    }

    private static function onLogout($event): void
    {
        try {
            if (!$event->user) {
                return;
            }
            self::record(array_merge(self::actor($event->user), self::base('auth.logout', 'Logout')));
        } catch (\Throwable $e) {
        }
    }

    private static function onFailed($event): void
    {
        try {
            $cred = (array) ($event->credentials ?? []);
            $typed = $cred['username'] ?? $cred['user'] ?? $cred['email'] ?? '?';
            if ($event->user) {
                $actor = self::actor($event->user);
            } else {
                $actor = ['actor_id' => null, 'actor_name' => self::clean($typed, 60), 'actor_email' => '', 'actor_admin' => 0];
            }
            // password TIDAK pernah dicatat
            self::record(array_merge($actor, self::base('auth.failed', 'Login gagal', '', '', 401)));
        } catch (\Throwable $e) {
        }
    }

    // ------------------------------------------------------------------ request capture

    public static function captureRequest(Request $request, $response): void
    {
        if ($request->attributes->get('ar_logged')) {
            return;
        }
        $request->attributes->set('ar_logged', true);

        $method = strtoupper((string) $request->method());
        $path = trim((string) $request->path(), '/');

        foreach (['auth/', 'api/remote', 'admin/antirusuh', 'ar-support', 'daemon'] as $skip) {
            if (str_starts_with($path, $skip)) {
                return;
            }
        }

        $user = $request->user();
        if (!$user) {
            return;
        }

        $rule = self::classify($method, $path);
        if ($rule === null) {
            return;
        }

        $status = method_exists($response, 'getStatusCode') ? (int) $response->getStatusCode() : 200;
        if ($status >= 400 && $status !== 403) {
            return;
        }

        [$action, $label, $keys] = $rule;

        $parts = [];
        foreach ($keys as $key) {
            $value = $request->input($key);
            if ($value === null || $value === '' || $value === []) {
                continue;
            }
            $parts[] = $key . '=' . self::clean($value, 120);
        }

        self::record(array_merge(
            self::actor($user),
            self::base($action, $label, self::describeTarget($request), self::clean(implode(' ', $parts), 250), $status)
        ));
    }

    private static function rules(): array
    {
        // [metode: M = semua yang mengubah data | GET | POST | DELETE, regex path, kode aksi, label, input yang boleh dicatat]
        return [
            ['M', '#^api/client/servers/[^/]+/power$#', 'server.power', 'Power server', ['signal']],
            ['M', '#^api/client/servers/[^/]+/command$#', 'server.command', 'Kirim command ke console', []],
            ['M', '#^api/client/servers/[^/]+/files/write$#', 'file.write', 'Simpan/edit file', ['file']],
            ['M', '#^api/client/servers/[^/]+/files/delete$#', 'file.delete', 'Hapus file', ['root', 'files']],
            ['M', '#^api/client/servers/[^/]+/files/rename$#', 'file.rename', 'Rename/pindah file', ['root', 'files']],
            ['M', '#^api/client/servers/[^/]+/files/copy$#', 'file.copy', 'Copy file', ['location']],
            ['M', '#^api/client/servers/[^/]+/files/compress$#', 'file.compress', 'Compress file', ['root', 'files']],
            ['M', '#^api/client/servers/[^/]+/files/decompress$#', 'file.decompress', 'Extract file', ['root', 'file']],
            ['M', '#^api/client/servers/[^/]+/files/create-folder$#', 'file.mkdir', 'Buat folder', ['root', 'name']],
            ['M', '#^api/client/servers/[^/]+/files/chmod$#', 'file.chmod', 'Ubah permission file', ['root']],
            ['M', '#^api/client/servers/[^/]+/files/pull$#', 'file.pull', 'Pull file dari URL', ['url', 'directory']],
            ['GET', '#^api/client/servers/[^/]+/files/download$#', 'file.download', 'Download file', ['file']],
            ['GET', '#^api/client/servers/[^/]+/files/upload$#', 'file.upload', 'Upload file', []],
            ['M', '#^api/client/servers/[^/]+/backups$#', 'backup.create', 'Buat backup', ['name']],
            ['M', '#^api/client/servers/[^/]+/backups/[^/]+/restore$#', 'backup.restore', 'Restore backup', []],
            ['M', '#^api/client/servers/[^/]+/backups/[^/]+$#', 'backup.change', 'Ubah/hapus backup', []],
            ['GET', '#^api/client/servers/[^/]+/backups/[^/]+/download$#', 'backup.download', 'Download backup', []],
            ['M', '#^api/client/servers/[^/]+/databases#', 'db.change', 'Aksi database server', []],
            ['M', '#^api/client/servers/[^/]+/schedules#', 'schedule.change', 'Aksi schedule', []],
            ['M', '#^api/client/servers/[^/]+/network#', 'network.change', 'Aksi network/allocation', []],
            ['M', '#^api/client/servers/[^/]+/startup#', 'server.startup', 'Ubah startup variable', ['key']],
            ['M', '#^api/client/servers/[^/]+/settings/rename$#', 'server.rename', 'Rename server', ['name']],
            ['M', '#^api/client/servers/[^/]+/settings/reinstall$#', 'server.reinstall', 'Reinstall server', []],
            ['M', '#^api/client/servers/[^/]+/settings#', 'server.settings', 'Ubah pengaturan server', []],
            ['M', '#^api/client/servers/[^/]+/users#', 'server.subuser', 'Aksi subuser server', ['email']],
            ['M', '#^api/client/account/email$#', 'account.email', 'Ubah email akun', []],
            ['M', '#^api/client/account/password$#', 'account.password', 'Ubah password akun', []],
            ['M', '#^api/client/account/api-keys#', 'account.apikey', 'Aksi API key akun', ['description']],
            ['M', '#^api/client/account/two-factor#', 'account.2fa', 'Aksi 2FA akun', []],
            ['M', '#^api/client/account/ssh-keys#', 'account.ssh', 'Aksi SSH key akun', []],
            ['M', '#^admin/servers/new$#', 'admin.server.create', 'Admin: buat server', ['name']],
            ['M', '#^admin/servers/view/[^/]+/delete$#', 'admin.server.delete', 'Admin: hapus server', []],
            ['M', '#^admin/servers/view/#', 'admin.server.update', 'Admin: ubah/aksi server', ['name']],
            ['M', '#^admin/users/new$#', 'admin.user.create', 'Admin: buat user', ['username', 'email']],
            ['DELETE', '#^admin/users/view/[^/]+$#', 'admin.user.delete', 'Admin: hapus user', []],
            ['M', '#^admin/users/view/#', 'admin.user.update', 'Admin: ubah user', ['username', 'email']],
            ['M', '#^admin/nodes/#', 'admin.node.change', 'Admin: aksi node', ['name']],
            ['M', '#^admin/settings#', 'admin.settings', 'Admin: ubah settings', []],
            ['POST', '#^api/application/servers$#', 'api.server.create', 'API: buat server', ['name']],
            ['POST', '#^api/application/users$#', 'api.user.create', 'API: buat user', ['username', 'email']],
            ['DELETE', '#^api/application/users/[^/]+$#', 'api.user.delete', 'API: hapus user', []],
            ['DELETE', '#^api/application/servers/[^/]+(/force)?$#', 'api.server.delete', 'API: hapus server', []],
        ];
    }

    private static function classify(string $method, string $path): ?array
    {
        $mutating = in_array($method, ['POST', 'PUT', 'PATCH', 'DELETE'], true);

        foreach (self::rules() as [$m, $regex, $action, $label, $keys]) {
            $ok = $m === 'M' ? $mutating : $m === $method;
            if ($ok && preg_match($regex, $path)) {
                return [$action, $label, $keys];
            }
        }

        if ($mutating && preg_match('#^(api/client|admin|api/application)/#', $path)) {
            return ['other.' . strtolower($method), self::clean($method . ' /' . $path, 100), []];
        }

        return null;
    }

    /** Snapshot target dari parameter route, supaya tetap terbaca walau datanya sudah dihapus. */
    private static function describeTarget(Request $request): string
    {
        $route = $request->route();
        if (!$route) {
            return '';
        }

        $parts = [];
        foreach ($route->parameters() as $name => $value) {
            if ($value instanceof \Pterodactyl\Models\User) {
                $parts[] = 'user: ' . $value->username . ' (' . $value->email . ')';
            } elseif ($value instanceof \Pterodactyl\Models\Server) {
                $owner = '';
                try {
                    $owner = $value->user ? ' | pemilik: ' . $value->user->username : '';
                } catch (\Throwable $e) {
                }
                $short = $value->uuidShort ?? substr((string) $value->uuid, 0, 8);
                $parts[] = 'server: ' . $value->name . ' [' . $short . ']' . $owner;
            } elseif ($value instanceof Model) {
                $parts[] = strtolower(class_basename($value)) . ': ' . ($value->name ?? $value->username ?? $value->getKey());
            } elseif (is_scalar($value) && $name !== 'react') {
                $parts[] = $name . ': ' . $value;
            }
        }

        return self::clean(implode(' | ', $parts), 250);
    }

    // ------------------------------------------------------------------ write

    public static function record(array $d, bool $force = false): void
    {
        try {
            $cooldown = self::cooldown();
            if (!$force && $cooldown > 0) {
                $key = 'anti_rusuh:cd:' . md5(implode('|', [
                    $d['actor_id'] ?? 0, $d['actor_name'] ?? '', $d['action'] ?? '', $d['target'] ?? '',
                    $d['detail'] ?? '', $d['ip'] ?? '', $d['status'] ?? 200,
                ]));
                try {
                    if (!Cache::add($key, 1, $cooldown)) {
                        return;
                    }
                } catch (\Throwable $e) {
                    // cache bermasalah: tetap dicatat
                }
            }

            DB::table(self::TABLE_LOGS)->insert([
                'created_at' => now(),
                'actor_id' => $d['actor_id'] ?? null,
                'actor_name' => self::clean($d['actor_name'] ?? '', 191),
                'actor_email' => self::clean($d['actor_email'] ?? '', 191),
                'actor_admin' => !empty($d['actor_admin']) ? 1 : 0,
                'action' => self::clean($d['action'] ?? '', 64),
                'label' => self::clean($d['label'] ?? '', 191),
                'target' => self::clean($d['target'] ?? '', 255),
                'detail' => self::clean($d['detail'] ?? '', 255),
                'ip' => self::clean($d['ip'] ?? '', 45),
                'method' => self::clean($d['method'] ?? '', 10),
                'path' => self::clean($d['path'] ?? '', 255),
                'status' => (int) ($d['status'] ?? 200),
            ]);

            self::maybePrune();
        } catch (\Throwable $e) {
            // log tidak boleh merusak request
        }
    }

    public static function recordManual($user, string $action, string $label, string $detail = '', string $target = ''): void
    {
        self::record(array_merge(self::actor($user), self::base($action, $label, $target, $detail)), true);
    }

    /** Hapus log yang lebih tua dari 30 hari (maksimal sekali per jam). */
    public static function maybePrune(): void
    {
        try {
            if (Cache::add('anti_rusuh:prune', 1, 3600)) {
                DB::table(self::TABLE_LOGS)->where('created_at', '<', now()->subDays(self::RETENTION_DAYS))->delete();
            }
        } catch (\Throwable $e) {
        }
    }

    // ------------------------------------------------------------------ install

    public static function ensureTables(): void
    {
        if (!Schema::hasTable(self::TABLE_LOGS)) {
            Schema::create(self::TABLE_LOGS, function ($t) {
                $t->bigIncrements('id');
                $t->timestamp('created_at')->nullable()->index();
                $t->unsignedInteger('actor_id')->nullable()->index();
                $t->string('actor_name', 191)->default('');
                $t->string('actor_email', 191)->default('');
                $t->boolean('actor_admin')->default(false);
                $t->string('action', 64)->default('')->index();
                $t->string('label', 191)->default('');
                $t->string('target', 255)->default('');
                $t->string('detail', 255)->default('');
                $t->string('ip', 45)->default('');
                $t->string('method', 10)->default('');
                $t->string('path', 255)->default('');
                $t->unsignedSmallInteger('status')->default(200);
            });
        }

        if (!Schema::hasTable(self::TABLE_SUPPORT)) {
            Schema::create(self::TABLE_SUPPORT, function ($t) {
                $t->bigIncrements('id');
                $t->timestamp('created_at')->nullable()->index();
                $t->unsignedInteger('user_id')->nullable();
                $t->string('username', 191)->default('');
                $t->string('email', 191)->default('');
                $t->string('type', 16)->default('report');
                $t->text('message');
                $t->string('ip', 45)->default('');
                $t->boolean('is_read')->default(false);
            });
        }
    }
}
AR_F1_EOF
chmod 644 "$PANEL_DIR/app/Helpers/AntiRusuhLog.php"

mkdir -p "$(dirname "$PANEL_DIR/app/Http/Middleware/AntiRusuhLogger.php")"
cat > "$PANEL_DIR/app/Http/Middleware/AntiRusuhLogger.php" <<'AR_F2_EOF'
<?php

namespace Pterodactyl\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Pterodactyl\Helpers\AntiRusuhLog;

/**
 * Mencatat aksi user SETELAH response dikirim (terminate), jadi tidak memperlambat request.
 */
class AntiRusuhLogger
{
    public function handle(Request $request, Closure $next)
    {
        return $next($request);
    }

    public function terminate(Request $request, $response): void
    {
        try {
            AntiRusuhLog::captureRequest($request, $response);
        } catch (\Throwable $e) {
            // jangan pernah mengganggu panel
        }
    }
}
AR_F2_EOF
chmod 644 "$PANEL_DIR/app/Http/Middleware/AntiRusuhLogger.php"

mkdir -p "$(dirname "$PANEL_DIR/app/Http/Controllers/Admin/AntiRusuhLogController.php")"
cat > "$PANEL_DIR/app/Http/Controllers/Admin/AntiRusuhLogController.php" <<'AR_F3_EOF'
<?php

namespace Pterodactyl\Http\Controllers\Admin;

use Illuminate\Contracts\View\Factory as ViewFactory;
use Illuminate\Contracts\View\View;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\Pagination\LengthAwarePaginator;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Prologue\Alerts\AlertsMessageBag;
use Pterodactyl\Helpers\AntiRusuhLog;
use Pterodactyl\Http\Controllers\Controller;

/**
 * Halaman Log Aktivitas + Support. SELALU hanya untuk Admin ID 1.
 */
class AntiRusuhLogController extends Controller
{
    public function __construct(private AlertsMessageBag $alert, private ViewFactory $view)
    {
    }

    private function guard(Request $request): void
    {
        if (!$request->user() || (int) $request->user()->id !== 1) {
            abort(403, 'Akses ditolak');
        }
    }

    private function back(Request $request): RedirectResponse
    {
        return redirect()->route('admin.antirusuh', ['tab' => $request->input('tab') === 'support' ? 'support' : 'logs']);
    }

    public function index(Request $request): View
    {
        $this->guard($request);
        AntiRusuhLog::maybePrune();

        $tab = $request->query('tab') === 'support' ? 'support' : 'logs';
        $days = in_array((int) $request->query('days'), [1, 7, 30], true) ? (int) $request->query('days') : 30;
        $filters = [
            'q' => trim((string) $request->query('q', '')),
            'action' => (string) $request->query('action', ''),
            'who' => (string) $request->query('who', ''),
        ];

        $logs = new LengthAwarePaginator([], 0, 50);
        $support = new LengthAwarePaginator([], 0, 25);
        $unread = 0;
        $total = 0;

        try {
            if (Schema::hasTable(AntiRusuhLog::TABLE_LOGS)) {
                $q = DB::table(AntiRusuhLog::TABLE_LOGS)->where('created_at', '>=', now()->subDays($days));

                if ($filters['q'] !== '') {
                    $like = '%' . $filters['q'] . '%';
                    $q->where(function ($w) use ($like) {
                        $w->where('actor_name', 'like', $like)
                            ->orWhere('actor_email', 'like', $like)
                            ->orWhere('label', 'like', $like)
                            ->orWhere('target', 'like', $like)
                            ->orWhere('detail', 'like', $like)
                            ->orWhere('ip', 'like', $like);
                    });
                }
                if ($filters['action'] === 'denied') {
                    $q->where('status', 403);
                } elseif ($filters['action'] !== '') {
                    $q->where('action', 'like', $filters['action'] . '.%');
                }
                if ($filters['who'] === 'admin') {
                    $q->where('actor_admin', 1);
                } elseif ($filters['who'] === 'user') {
                    $q->where('actor_admin', 0);
                }

                $total = (clone $q)->count();
                $logs = $q->orderByDesc('id')->paginate(50)->appends($request->query());
            }

            if (Schema::hasTable(AntiRusuhLog::TABLE_SUPPORT)) {
                $unread = DB::table(AntiRusuhLog::TABLE_SUPPORT)->where('is_read', 0)->count();
                $support = DB::table(AntiRusuhLog::TABLE_SUPPORT)->orderByDesc('id')->paginate(25, ['*'], 'spage')->appends($request->query());
            }
        } catch (\Throwable $e) {
            // tabel belum ada / DB bermasalah: tampilkan halaman kosong
        }

        return $this->view->make('admin.antirusuh.index', [
            'tab' => $tab,
            'days' => $days,
            'filters' => $filters,
            'logs' => $logs,
            'support' => $support,
            'unread' => $unread,
            'total' => $total,
            'logsOn' => AntiRusuhLog::flag('logs'),
            'supportOn' => AntiRusuhLog::flag('support'),
            'cooldown' => AntiRusuhLog::cooldown(),
            'supportCooldown' => (int) AntiRusuhLog::setting('anti_rusuh_support_cooldown', 60),
            'retention' => AntiRusuhLog::RETENTION_DAYS,
        ]);
    }

    public function clear(Request $request): RedirectResponse
    {
        $this->guard($request);

        $n = 0;
        try {
            $n = DB::table(AntiRusuhLog::TABLE_LOGS)->delete();
        } catch (\Throwable $e) {
        }

        AntiRusuhLog::recordManual($request->user(), 'admin.log.clear', 'Admin: log aktivitas dibersihkan', $n . ' entri dihapus');
        $this->alert->success('Semua log aktivitas sudah dihapus (' . $n . ' entri).')->flash();

        return redirect()->route('admin.antirusuh', ['tab' => 'logs']);
    }

    public function settings(Request $request): RedirectResponse
    {
        $this->guard($request);

        $cooldown = max(0, min(3600, (int) $request->input('cooldown', 5)));
        AntiRusuhLog::setSetting('anti_rusuh_log_cooldown', (string) $cooldown);

        if ($request->has('support_cooldown')) {
            $support = max(0, min(86400, (int) $request->input('support_cooldown', 60)));
            AntiRusuhLog::setSetting('anti_rusuh_support_cooldown', (string) $support);
        }

        $this->alert->success('Pengaturan cooldown disimpan.')->flash();

        return $this->back($request);
    }

    public function supportRead(Request $request, $id): RedirectResponse
    {
        $this->guard($request);
        DB::table(AntiRusuhLog::TABLE_SUPPORT)->where('id', (int) $id)->update(['is_read' => 1]);

        return redirect()->route('admin.antirusuh', ['tab' => 'support']);
    }

    public function supportDelete(Request $request, $id): RedirectResponse
    {
        $this->guard($request);
        DB::table(AntiRusuhLog::TABLE_SUPPORT)->where('id', (int) $id)->delete();
        $this->alert->success('Pesan dihapus.')->flash();

        return redirect()->route('admin.antirusuh', ['tab' => 'support']);
    }

    public function supportClear(Request $request): RedirectResponse
    {
        $this->guard($request);
        $n = DB::table(AntiRusuhLog::TABLE_SUPPORT)->delete();
        $this->alert->success('Semua pesan support dihapus (' . $n . ').')->flash();

        return redirect()->route('admin.antirusuh', ['tab' => 'support']);
    }
}
AR_F3_EOF
chmod 644 "$PANEL_DIR/app/Http/Controllers/Admin/AntiRusuhLogController.php"

mkdir -p "$(dirname "$PANEL_DIR/app/Http/Controllers/Base/AntiRusuhSupportController.php")"
cat > "$PANEL_DIR/app/Http/Controllers/Base/AntiRusuhSupportController.php" <<'AR_F4_EOF'
<?php

namespace Pterodactyl\Http\Controllers\Base;

use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Pterodactyl\Helpers\AntiRusuhLog;
use Pterodactyl\Http\Controllers\Controller;

/**
 * Menerima Report / Ide dari tombol di kanan atas panel. Nama & email diambil dari akun yang login (tidak bisa dipalsukan).
 */
class AntiRusuhSupportController extends Controller
{
    public function submit(Request $request): JsonResponse
    {
        $user = $request->user();
        if (!$user) {
            return new JsonResponse(['error' => 'Kamu belum login.'], 401);
        }
        if (!AntiRusuhLog::flag('support')) {
            return new JsonResponse(['error' => 'Fitur support tidak aktif.'], 404);
        }

        $type = $request->input('type') === 'ide' ? 'ide' : 'report';
        $message = trim((string) $request->input('message'));
        $length = mb_strlen($message);

        if ($length < 5) {
            return new JsonResponse(['error' => 'Pesan terlalu pendek (minimal 5 karakter).'], 422);
        }
        if ($length > 1500) {
            return new JsonResponse(['error' => 'Pesan terlalu panjang (maksimal 1500 karakter).'], 422);
        }

        $cooldown = max(0, (int) AntiRusuhLog::setting('anti_rusuh_support_cooldown', 60));
        if ($cooldown > 0) {
            try {
                if (!Cache::add('anti_rusuh:support:' . $user->id, 1, $cooldown)) {
                    return new JsonResponse(['error' => 'Terlalu cepat, coba lagi beberapa saat lagi.'], 429);
                }
            } catch (\Throwable $e) {
                // cache bermasalah: lanjut saja
            }
        }

        DB::table(AntiRusuhLog::TABLE_SUPPORT)->insert([
            'created_at' => now(),
            'user_id' => $user->id,
            'username' => AntiRusuhLog::clean($user->username, 191),
            'email' => AntiRusuhLog::clean($user->email, 191),
            'type' => $type,
            'message' => $message,
            'ip' => AntiRusuhLog::ip(),
            'is_read' => 0,
        ]);

        return new JsonResponse(['ok' => true]);
    }
}
AR_F4_EOF
chmod 644 "$PANEL_DIR/app/Http/Controllers/Base/AntiRusuhSupportController.php"

mkdir -p "$(dirname "$PANEL_DIR/resources/views/admin/antirusuh/index.blade.php")"
cat > "$PANEL_DIR/resources/views/admin/antirusuh/index.blade.php" <<'AR_F5_EOF'
@extends('layouts.admin')

@section('title')
    Log Aktivitas
@endsection

@section('content-header')
    <h1>Log Aktivitas<small>Semua aksi user &amp; admin. Hanya terlihat oleh Admin ID 1.</small></h1>
    <ol class="breadcrumb">
        <li><a href="{{ route('admin.index') }}">Admin</a></li>
        <li class="active">Log Aktivitas</li>
    </ol>
@endsection

@section('content')
    <div class="row">
        <div class="col-xs-12">
            <div class="nav-tabs-custom nav-tabs-floating">
                <ul class="nav nav-tabs">
                    <li class="{{ $tab === 'logs' ? 'active' : '' }}"><a href="{{ route('admin.antirusuh', ['tab' => 'logs']) }}">Log Aktivitas</a></li>
                    <li class="{{ $tab === 'support' ? 'active' : '' }}">
                        <a href="{{ route('admin.antirusuh', ['tab' => 'support']) }}">Support / Ide @if($unread > 0)<span class="label label-danger">{{ $unread }}</span>@endif</a>
                    </li>
                </ul>
            </div>
        </div>
    </div>

    @if($tab === 'logs')
        @if(!$logsOn)
            <div class="alert alert-warning">Fitur log aktivitas belum aktif. Install <strong>V11</strong> lewat bot untuk mengaktifkan pencatatan.</div>
        @endif
        <div class="row">
            <div class="col-md-8">
                <div class="box box-primary">
                    <div class="box-header with-border"><h3 class="box-title">Filter</h3></div>
                    <form method="GET" action="{{ route('admin.antirusuh') }}">
                        <input type="hidden" name="tab" value="logs">
                        <div class="box-body">
                            <div class="row">
                                <div class="form-group col-md-4">
                                    <label class="control-label">Cari</label>
                                    <input type="text" name="q" value="{{ $filters['q'] }}" class="form-control" placeholder="user, email, server, IP...">
                                </div>
                                <div class="form-group col-md-3">
                                    <label class="control-label">Jenis</label>
                                    <select name="action" class="form-control">
                                        <option value="">Semua</option>
                                        @foreach(['auth' => 'Login / Logout', 'server' => 'Server', 'file' => 'File', 'backup' => 'Backup', 'admin' => 'Admin panel', 'api' => 'API key', 'account' => 'Akun', 'denied' => 'Ditolak (403)'] as $key => $name)
                                            <option value="{{ $key }}" @if($filters['action'] === $key) selected @endif>{{ $name }}</option>
                                        @endforeach
                                    </select>
                                </div>
                                <div class="form-group col-md-2">
                                    <label class="control-label">Pelaku</label>
                                    <select name="who" class="form-control">
                                        <option value="">Semua</option>
                                        <option value="admin" @if($filters['who'] === 'admin') selected @endif>Admin</option>
                                        <option value="user" @if($filters['who'] === 'user') selected @endif>User</option>
                                    </select>
                                </div>
                                <div class="form-group col-md-3">
                                    <label class="control-label">Periode</label>
                                    <select name="days" class="form-control">
                                        <option value="1" @if($days === 1) selected @endif>24 jam terakhir</option>
                                        <option value="7" @if($days === 7) selected @endif>7 hari terakhir</option>
                                        <option value="30" @if($days === 30) selected @endif>30 hari terakhir</option>
                                    </select>
                                </div>
                            </div>
                        </div>
                        <div class="box-footer">
                            <button type="submit" class="btn btn-sm btn-primary pull-right">Terapkan</button>
                            <span class="text-muted"><small>{{ $total }} entri &middot; zona waktu {{ config('app.timezone') }} &middot; log otomatis dihapus setelah {{ $retention }} hari</small></span>
                        </div>
                    </form>
                </div>
            </div>
            <div class="col-md-4">
                <div class="box box-warning">
                    <div class="box-header with-border"><h3 class="box-title">Cooldown &amp; Hapus</h3></div>
                    <form method="POST" action="{{ route('admin.antirusuh.settings') }}">
                        {!! csrf_field() !!}
                        <input type="hidden" name="tab" value="logs">
                        <div class="box-body">
                            <label class="control-label">Cooldown log (detik)</label>
                            <input type="number" min="0" max="3600" name="cooldown" value="{{ $cooldown }}" class="form-control">
                            <p class="text-muted"><small>Aksi yang sama dari user yang sama dalam jeda ini hanya dicatat sekali. Isi 0 untuk mencatat semuanya.</small></p>
                        </div>
                        <div class="box-footer">
                            <button type="submit" class="btn btn-sm btn-primary">Simpan</button>
                        </div>
                    </form>
                    <form method="POST" action="{{ route('admin.antirusuh.clear') }}" onsubmit="return confirm('Hapus SEMUA log aktivitas? Tindakan ini tidak bisa dibatalkan.');">
                        {!! csrf_field() !!}
                        <div class="box-footer">
                            <button type="submit" class="btn btn-sm btn-danger">Hapus semua log</button>
                        </div>
                    </form>
                </div>
            </div>
        </div>

        <div class="row">
            <div class="col-xs-12">
                <div class="box box-primary">
                    <div class="box-header with-border"><h3 class="box-title">Aktivitas</h3></div>
                    <div class="box-body table-responsive no-padding">
                        <table class="table table-hover">
                            <tbody>
                                <tr>
                                    <th>Waktu</th>
                                    <th>User</th>
                                    <th>Aksi</th>
                                    <th>Target / Detail</th>
                                    <th>IP</th>
                                </tr>
                                @forelse($logs as $log)
                                    <tr @if((int) $log->status === 403 || (int) $log->status === 401) class="danger" @endif>
                                        <td><code>{{ $log->created_at }}</code></td>
                                        <td>
                                            {{ $log->actor_name }}
                                            @if($log->actor_admin)<span class="label label-warning">admin</span>@else<span class="label label-default">user</span>@endif
                                            <br><small class="text-muted">{{ $log->actor_email }}</small>
                                        </td>
                                        <td>
                                            {{ $log->label }}
                                            @if((int) $log->status === 403)<span class="label label-danger">DITOLAK</span>@endif
                                            @if((int) $log->status === 401)<span class="label label-danger">GAGAL</span>@endif
                                        </td>
                                        <td>
                                            {{ $log->target }}
                                            @if($log->detail !== '')<br><small class="text-muted">{{ $log->detail }}</small>@endif
                                        </td>
                                        <td><code>{{ $log->ip }}</code></td>
                                    </tr>
                                @empty
                                    <tr><td colspan="5" class="text-center text-muted">Belum ada aktivitas pada periode ini.</td></tr>
                                @endforelse
                            </tbody>
                        </table>
                    </div>
                    @if($logs->hasPages())
                        <div class="box-footer with-border">
                            <div class="col-md-12 text-center">{!! $logs->render() !!}</div>
                        </div>
                    @endif
                </div>
            </div>
        </div>
    @else
        @if(!$supportOn)
            <div class="alert alert-warning">Fitur support belum aktif. Install <strong>V12</strong> lewat bot untuk menampilkan tombol Report / Ide ke user.</div>
        @endif
        <div class="row">
            <div class="col-xs-12">
                <div class="box box-primary">
                    <div class="box-header with-border">
                        <h3 class="box-title">Pesan dari user</h3>
                        <div class="box-tools">
                            <form method="POST" action="{{ route('admin.antirusuh.support.clear') }}" style="display:inline-block;" onsubmit="return confirm('Hapus SEMUA pesan support?');">
                                {!! csrf_field() !!}
                                <button type="submit" class="btn btn-xs btn-danger">Hapus semua</button>
                            </form>
                        </div>
                    </div>
                    <form method="POST" action="{{ route('admin.antirusuh.settings') }}" class="box-body" style="border-bottom:1px solid #f4f4f4;">
                        {!! csrf_field() !!}
                        <input type="hidden" name="tab" value="support">
                        <input type="hidden" name="cooldown" value="{{ $cooldown }}">
                        <div class="form-inline">
                            <label class="control-label">Cooldown kirim pesan per user (detik)</label>
                            <input type="number" min="0" max="86400" name="support_cooldown" value="{{ $supportCooldown }}" class="form-control" style="width:110px;">
                            <button type="submit" class="btn btn-sm btn-primary">Simpan</button>
                        </div>
                    </form>
                    <div class="box-body table-responsive no-padding">
                        <table class="table table-hover">
                            <tbody>
                                <tr>
                                    <th>Waktu</th>
                                    <th>Dari</th>
                                    <th>Email</th>
                                    <th>Jenis</th>
                                    <th>Pesan</th>
                                    <th></th>
                                </tr>
                                @forelse($support as $row)
                                    <tr @if(!$row->is_read) style="font-weight:bold;" @endif>
                                        <td><code>{{ $row->created_at }}</code></td>
                                        <td>{{ $row->username }}</td>
                                        <td>{{ $row->email }}</td>
                                        <td>
                                            @if($row->type === 'ide')<span class="label label-success">Ide</span>@else<span class="label label-danger">Report</span>@endif
                                        </td>
                                        <td style="max-width:420px; white-space:normal; word-wrap:break-word;">{!! nl2br(e($row->message)) !!}</td>
                                        <td class="text-right" style="white-space:nowrap;">
                                            @if(!$row->is_read)
                                                <form method="POST" action="{{ route('admin.antirusuh.support.read', ['id' => $row->id]) }}" style="display:inline-block;">
                                                    {!! csrf_field() !!}
                                                    <button type="submit" class="btn btn-xs btn-default">Tandai dibaca</button>
                                                </form>
                                            @endif
                                            <form method="POST" action="{{ route('admin.antirusuh.support.delete', ['id' => $row->id]) }}" style="display:inline-block;">
                                                {!! csrf_field() !!}
                                                <button type="submit" class="btn btn-xs btn-danger">Hapus</button>
                                            </form>
                                        </td>
                                    </tr>
                                @empty
                                    <tr><td colspan="6" class="text-center text-muted">Belum ada pesan.</td></tr>
                                @endforelse
                            </tbody>
                        </table>
                    </div>
                    @if($support->hasPages())
                        <div class="box-footer with-border">
                            <div class="col-md-12 text-center">{!! $support->render() !!}</div>
                        </div>
                    @endif
                </div>
            </div>
        </div>
    @endif
@endsection
AR_F5_EOF
chmod 644 "$PANEL_DIR/resources/views/admin/antirusuh/index.blade.php"

mkdir -p "$(dirname "$PANEL_DIR/resources/views/antirusuh/support-widget.blade.php")"
cat > "$PANEL_DIR/resources/views/antirusuh/support-widget.blade.php" <<'AR_F6_EOF'
@if (\Pterodactyl\Helpers\AntiRusuhLog::flag('support') && \Illuminate\Support\Facades\Auth::check())
<div id="ar-sp-root" data-token="{{ csrf_token() }}">
    <div id="ar-sp-modal" style="display:none;">
        <div id="ar-sp-box">
            <div id="ar-sp-title">Kirim Report / Ide</div>
            <select id="ar-sp-type">
                <option value="report">Report masalah</option>
                <option value="ide">Beri ide</option>
            </select>
            <textarea id="ar-sp-msg" maxlength="1500" rows="5" placeholder="Tulis pesanmu di sini..."></textarea>
            <div id="ar-sp-status"></div>
            <div id="ar-sp-actions">
                <button id="ar-sp-cancel" type="button">Batal</button>
                <button id="ar-sp-send" type="button">Kirim</button>
            </div>
        </div>
    </div>
</div>
@verbatim
<style>
#ar-sp-modal{position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,.6);align-items:center;justify-content:center}
#ar-sp-box{width:92%;max-width:420px;background:#1f2937;color:#e5e7eb;border-radius:10px;padding:16px;font:14px/1.4 sans-serif;box-shadow:0 10px 30px rgba(0,0,0,.5)}
#ar-sp-title{font-weight:700;font-size:16px;margin-bottom:10px}
#ar-sp-type,#ar-sp-msg{width:100%;box-sizing:border-box;margin-bottom:8px;padding:8px;border:1px solid #374151;border-radius:6px;background:#111827;color:#e5e7eb;font:inherit}
#ar-sp-msg{resize:vertical}
#ar-sp-status{min-height:18px;font-size:12px;margin-bottom:8px}
#ar-sp-actions{display:flex;gap:8px;justify-content:flex-end}
#ar-sp-actions button{padding:7px 14px;border:0;border-radius:6px;cursor:pointer;font:600 13px sans-serif;color:#fff;background:#4b5563}
#ar-sp-send{background:#2563eb !important}
#ar-sp-send[disabled]{opacity:.6;cursor:default}
</style>
<script>
(function () {
  var root = document.getElementById('ar-sp-root');
  if (!root) return;
  var modal = document.getElementById('ar-sp-modal');
  var msg = document.getElementById('ar-sp-msg');
  var type = document.getElementById('ar-sp-type');
  var status = document.getElementById('ar-sp-status');
  var send = document.getElementById('ar-sp-send');
  function setStatus(text, ok) { status.textContent = text || ''; status.style.color = ok ? '#34d399' : '#f87171'; }
  function open() { modal.style.display = 'flex'; setStatus(''); msg.focus(); }
  function close() { modal.style.display = 'none'; }
  // Ikon amplop di navbar atas (sebelah search). Gaya mengikuti item navbar lain karena sama-sama <button> di dalam navbar.
  var NAV_ID = 'ar-sp-nav';
  var ICON = '<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="5" width="18" height="14" rx="2"></rect><path d="M3 7l9 6 9-6"></path></svg>';
  function mount() {
    if (document.getElementById(NAV_ID)) return;
    var account = document.querySelector('a[href="/account"]');
    if (!account || !account.parentElement) return;
    var bar = account.parentElement;
    var item = document.createElement('button');
    item.id = NAV_ID;
    item.type = 'button';
    item.title = 'Report / Beri Ide';
    item.setAttribute('aria-label', 'Report / Beri Ide');
    item.innerHTML = ICON;
    item.addEventListener('click', open);
    var first = bar.firstElementChild;
    if (first && first.nextSibling) { bar.insertBefore(item, first.nextSibling); } else { bar.appendChild(item); }
  }
  var queued = false;
  new MutationObserver(function () {
    if (queued || document.getElementById(NAV_ID)) return;
    queued = true;
    requestAnimationFrame(function () { queued = false; mount(); });
  }).observe(document.body, { childList: true, subtree: true });
  mount();
  document.getElementById('ar-sp-cancel').addEventListener('click', close);
  modal.addEventListener('click', function (e) { if (e.target === modal) close(); });
  send.addEventListener('click', function () {
    var text = msg.value.trim();
    if (text.length < 5) { setStatus('Pesan terlalu pendek (minimal 5 karakter).', false); return; }
    send.disabled = true; setStatus('Mengirim...', true);
    fetch('/ar-support', {
      method: 'POST',
      credentials: 'same-origin',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-Requested-With': 'XMLHttpRequest',
        'X-CSRF-TOKEN': root.getAttribute('data-token')
      },
      body: JSON.stringify({ type: type.value, message: text })
    }).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (d) { return { ok: r.ok, data: d }; });
    }).then(function (res) {
      send.disabled = false;
      if (res.ok) { setStatus('Terkirim, terima kasih!', true); msg.value = ''; setTimeout(close, 1200); }
      else { setStatus((res.data && res.data.error) || 'Gagal mengirim, coba lagi.', false); }
    }).catch(function () { send.disabled = false; setStatus('Gagal mengirim, coba lagi.', false); });
  });
})();
</script>
@endverbatim
@endif
AR_F6_EOF
chmod 644 "$PANEL_DIR/resources/views/antirusuh/support-widget.blade.php"


for f in app/Helpers/AntiRusuhLog.php app/Http/Middleware/AntiRusuhLogger.php app/Http/Controllers/Admin/AntiRusuhLogController.php app/Http/Controllers/Base/AntiRusuhSupportController.php; do
  if ! "$PHP_BIN" -l "$PANEL_DIR/$f" >/dev/null 2>&1; then
    echo "❌ Error sintaks di $f, instalasi dibatalkan"
    exit 4
  fi
done

AR_TMP="$(mktemp -d)"
chmod 755 "$AR_TMP"

cat > "$AR_TMP/smoke.php" <<'AR_SMOKE_EOF'
<?php
// Cek: semua file Blade baru bisa dikompilasi menjadi PHP yang valid, sebelum menyentuh file panel yang sudah ada.
try {
    $panel = $argv[1];
    require $panel . '/vendor/autoload.php';
    $app = require $panel . '/bootstrap/app.php';
    $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
    $compiler = $app->make('blade.compiler');
    $bad = 0;
    foreach (array_slice($argv, 2) as $file) {
        $code = $compiler->compileString(file_get_contents($file));
        $tmp = tempnam(sys_get_temp_dir(), 'arb');
        file_put_contents($tmp, $code);
        $out = [];
        exec(escapeshellarg(PHP_BINARY) . ' -l ' . escapeshellarg($tmp) . ' 2>&1', $out, $rc);
        unlink($tmp);
        if ($rc !== 0) {
            echo "❌ Blade error: " . basename($file) . "\n";
            $bad++;
        }
    }
    exit($bad ? 5 : 0);
} catch (\Throwable $e) {
    echo "❌ Smoke test gagal: " . $e->getMessage() . "\n";
    exit(5);
}
AR_SMOKE_EOF

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


$ADMIN_ROUTES = <<<'PHPR'

// === Anti Rusuh: log aktivitas & support (hanya Admin ID 1) ===
\Illuminate\Support\Facades\Route::group(['prefix' => 'antirusuh'], function () {
    \Illuminate\Support\Facades\Route::get('/', [\Pterodactyl\Http\Controllers\Admin\AntiRusuhLogController::class, 'index'])->name('admin.antirusuh');
    \Illuminate\Support\Facades\Route::post('/clear', [\Pterodactyl\Http\Controllers\Admin\AntiRusuhLogController::class, 'clear'])->name('admin.antirusuh.clear');
    \Illuminate\Support\Facades\Route::post('/settings', [\Pterodactyl\Http\Controllers\Admin\AntiRusuhLogController::class, 'settings'])->name('admin.antirusuh.settings');
    \Illuminate\Support\Facades\Route::post('/support/clear', [\Pterodactyl\Http\Controllers\Admin\AntiRusuhLogController::class, 'supportClear'])->name('admin.antirusuh.support.clear');
    \Illuminate\Support\Facades\Route::post('/support/{id}/read', [\Pterodactyl\Http\Controllers\Admin\AntiRusuhLogController::class, 'supportRead'])->name('admin.antirusuh.support.read');
    \Illuminate\Support\Facades\Route::post('/support/{id}/delete', [\Pterodactyl\Http\Controllers\Admin\AntiRusuhLogController::class, 'supportDelete'])->name('admin.antirusuh.support.delete');
});
PHPR;

ar_patch("$panel/routes/admin.php", 'admin.antirusuh', function ($src) use ($ADMIN_ROUTES) {
    return rtrim($src) . "\n" . $ADMIN_ROUTES . "\n";
}, 'Route halaman Log Aktivitas');

ar_patch("$panel/resources/views/layouts/admin.blade.php", 'admin.antirusuh', function ($src) {
    $block = <<<'BLADE'
                    @if(\Illuminate\Support\Facades\Auth::check() && (int) \Illuminate\Support\Facades\Auth::user()->id === 1 && \Illuminate\Support\Facades\Route::has('admin.antirusuh'))
                        <li class="{{ \Illuminate\Support\Str::startsWith((string) \Illuminate\Support\Facades\Route::currentRouteName(), 'admin.antirusuh') ? 'active' : '' }}">
                            <a href="{{ route('admin.antirusuh') }}">
                                <i class="fa fa-history"></i> <span>Log Aktivitas</span>
                            </a>
                        </li>
                    @endif

BLADE;
    $needle = '<li class="header">SERVICE MANAGEMENT</li>';
    $pos = strpos($src, $needle);
    if ($pos === false) return null;
    $line = strrpos(substr($src, 0, $pos), "\n");
    $pos = $line === false ? $pos : $line + 1;
    return substr($src, 0, $pos) . $block . substr($src, $pos);
}, 'Menu sidebar Log Aktivitas');

$BASE_ROUTE = <<<'PHPR'

// === Anti Rusuh: kirim Report / Ide dari tombol kanan atas ===
\Illuminate\Support\Facades\Route::post('/ar-support', [\Pterodactyl\Http\Controllers\Base\AntiRusuhSupportController::class, 'submit'])->name('antirusuh.support.submit');
PHPR;

ar_patch("$panel/routes/base.php", 'ar-support', function ($src) use ($BASE_ROUTE) {
    return rtrim($src) . "\n" . $BASE_ROUTE . "\n";
}, 'Route kirim Report / Ide');

ar_patch("$panel/resources/views/templates/wrapper.blade.php", 'antirusuh.support-widget', function ($src) {
    $pos = strripos($src, '</body>');
    if ($pos === false) return null;
    return substr($src, 0, $pos) . "    @includeIf('antirusuh.support-widget')\n" . substr($src, $pos);
}, 'Ikon email Report / Ide di navbar');

exit($GLOBALS['ar_failed'] ? 4 : 0);
AR_PATCH_EOF

cat > "$AR_TMP/setup.php" <<'AR_SETUP_EOF'
<?php
// Buat tabel, aktifkan fitur, dan set default (hanya jika belum pernah diatur).
try {
    $panel = $argv[1];
    $feature = $argv[2];
    require $panel . '/vendor/autoload.php';
    $app = require $panel . '/bootstrap/app.php';
    $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

    \Pterodactyl\Helpers\AntiRusuhLog::ensureTables();
    \Pterodactyl\Helpers\AntiRusuhLog::setSetting('anti_rusuh_feature_' . $feature, 'true');
    \Illuminate\Support\Facades\Cache::forget('anti_rusuh:flag:' . $feature);

    if ($feature === 'logs' && \Pterodactyl\Helpers\AntiRusuhLog::setting('anti_rusuh_log_cooldown', null) === null) {
        \Pterodactyl\Helpers\AntiRusuhLog::setSetting('anti_rusuh_log_cooldown', '5');
    }
    if ($feature === 'support' && \Pterodactyl\Helpers\AntiRusuhLog::setting('anti_rusuh_support_cooldown', null) === null) {
        \Pterodactyl\Helpers\AntiRusuhLog::setSetting('anti_rusuh_support_cooldown', '60');
    }

    echo "✅ Tabel siap & fitur '" . $feature . "' diaktifkan\n";
    exit(0);
} catch (\Throwable $e) {
    echo "❌ Setup database gagal: " . $e->getMessage() . "\n";
    exit(6);
}
AR_SETUP_EOF
chmod 644 "$AR_TMP/smoke.php" "$AR_TMP/patch.php" "$AR_TMP/setup.php"

# Jalankan perintah panel sebagai user web server supaya file cache/log tidak jadi milik root
WEB_USER="$(stat -c '%U' "$PANEL_DIR/storage" 2>/dev/null || echo root)"
run_as_web() {
  if [ "$WEB_USER" != "root" ] && command -v runuser >/dev/null 2>&1; then
    runuser -u "$WEB_USER" -- "$@"
  else
    "$@"
  fi
}

# --- 2) cek dulu semua template Blade bisa dikompilasi ---
if ! run_as_web "$PHP_BIN" "$AR_TMP/smoke.php" "$PANEL_DIR" "$PANEL_DIR/resources/views/admin/antirusuh/index.blade.php" "$PANEL_DIR/resources/views/antirusuh/support-widget.blade.php"; then
  rm -rf "$AR_TMP"
  echo "❌ Template tidak valid, file panel yang sudah ada tidak disentuh"
  exit 4
fi

# --- 3) sisipkan hook ke file panel (backup .bak_ otomatis) ---
"$PHP_BIN" "$AR_TMP/patch.php" "$PANEL_DIR"
AR_RC=$?
if [ "$AR_RC" -ne 0 ]; then
  rm -rf "$AR_TMP"
  echo "❌ Support Report & Ide gagal dipasang (kode $AR_RC), cek pesan di atas"
  exit "$AR_RC"
fi

# --- 4) buat tabel + aktifkan fitur ---
if ! run_as_web "$PHP_BIN" "$AR_TMP/setup.php" "$PANEL_DIR" "support"; then
  rm -rf "$AR_TMP"
  exit 6
fi

(cd "$PANEL_DIR" && run_as_web "$PHP_BIN" artisan view:clear >/dev/null 2>&1) || true
if [ -f "$PANEL_DIR/bootstrap/cache/routes-v7.php" ]; then
  (cd "$PANEL_DIR" && run_as_web "$PHP_BIN" artisan route:clear >/dev/null 2>&1) || true
fi

rm -rf "$AR_TMP"

echo "✅ Support Report & Ide berhasil dipasang!"
echo "✉️  Ikon email muncul di navbar atas (sebelah search) untuk user yang login. Pesan masuk ke Admin -> Log Aktivitas -> tab Support / Ide."
