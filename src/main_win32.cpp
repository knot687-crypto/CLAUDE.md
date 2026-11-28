// Vortex Crosshair - Windows application
//
//  * Overlay thread: a click-through, always-on-top layered window that is
//    re-rendered and moved onto the mouse cursor once per display refresh.
//  * Main thread: tray icon, settings persistence, and the glass settings menu
//    (Right Shift by default) rendered by the portable UI in ui.cpp.
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <windowsx.h>
#include <dwmapi.h>
#include <shellapi.h>
#include <shlobj.h>

#include <algorithm>
#include <atomic>
#include <climits>
#include <cmath>
#include <cstring>
#include <string>
#include <vector>

#include "canvas.h"
#include "crosshair.h"
#include "settings.h"
#include "ui.h"

using namespace vx;

#ifndef WM_DPICHANGED
#define WM_DPICHANGED 0x02E0
#endif
#ifndef CREATE_WAITABLE_TIMER_HIGH_RESOLUTION
#define CREATE_WAITABLE_TIMER_HIGH_RESOLUTION 0x00000002
#endif
#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif
#ifndef WDA_NONE
#define WDA_NONE 0x00000000
#endif

namespace {

constexpr const wchar_t* kAppTitle = L"Vortex Crosshair";
constexpr const wchar_t* kMainClass = L"VortexCrosshair.Main";
constexpr const wchar_t* kMenuClass = L"VortexCrosshair.Menu";
constexpr const wchar_t* kOverlayClass = L"VortexCrosshair.Overlay";
constexpr const wchar_t* kMutexName = L"Local\\VortexCrosshair.SingleInstance";
constexpr const wchar_t* kRunKey = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr const wchar_t* kRunValue = L"VortexCrosshair";
constexpr float kPi = 3.14159265358979f;

enum : UINT {
    WM_APP_TRAY = WM_APP + 1,
    WM_APP_TOGGLE_MENU,
    WM_APP_SHOW_MENU,
    WM_APP_TOGGLE_CROSSHAIR,
    WM_APP_KEY_CAPTURED,
};
enum { TRAY_OPEN = 100, TRAY_TOGGLE, TRAY_QUIT };

// ------------------------------------------------------------ shared state
struct Shared {
    SRWLOCK lock = SRWLOCK_INIT;
    Settings settings;
    uint64_t version = 1;
    bool menuOpen = false;
    RECT menuRect{};
    int capture = 0;  // 1 = capture menu key, 2 = capture toggle key
    HWND notify = nullptr;
    std::atomic<bool> quit{false};
};
Shared g_shared;

HINSTANCE g_inst = nullptr;
HWND g_main = nullptr, g_menu = nullptr;
Settings g_settings;  // owned by the main thread
std::wstring g_settingsPath;
bool g_quit = false;
UINT g_taskbarCreated = 0;
HICON g_iconBig = nullptr, g_iconSmall = nullptr;

// menu state
SettingsPanel g_panel;
UIInput g_in;
bool g_menuVisible = false, g_uiDirty = true;
float g_scale = 1.f;
HDC g_menuDC = nullptr;
HBITMAP g_menuBmp = nullptr;
HGDIOBJ g_menuOldBmp = nullptr;
uint32_t* g_menuBits = nullptr;
int g_menuW = 0, g_menuH = 0;
Canvas g_canvas;
int g_glassLevel = 0;  // 0 none, 1 blur, 2 acrylic/mica
int g_uiCursor = CURSOR_ARROW;
bool g_trackingMouse = false;
HWND g_prevForeground = nullptr;
bool g_menuPlaced = false;
double g_lastUiFrame = 0;
double g_saveDue = 0;
bool g_savePending = false;
bool g_cursorsHidden = false;
HANDLE g_guardProcess = nullptr;
NOTIFYICONDATAW g_nid{};
bool g_trayV4 = false;

double nowSec() {
    static LARGE_INTEGER freq = [] {
        LARGE_INTEGER f;
        QueryPerformanceFrequency(&f);
        return f;
    }();
    LARGE_INTEGER c;
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart / (double)freq.QuadPart;
}

std::string toUtf8(const std::wstring& w) {
    if (w.empty()) return {};
    const int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), &s[0], n, nullptr, nullptr);
    return s;
}

std::wstring toWide(const std::string& s) {
    if (s.empty()) return {};
    const int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), &w[0], n);
    return w;
}

// ------------------------------------------------------------ OS helpers
DWORD windowsBuild() {
    typedef LONG(WINAPI * RtlGetVersionFn)(PRTL_OSVERSIONINFOW);
    static DWORD build = [] {
        RTL_OSVERSIONINFOW vi{};
        vi.dwOSVersionInfoSize = sizeof(vi);
        HMODULE nt = GetModuleHandleW(L"ntdll.dll");
        auto fn = nt ? (RtlGetVersionFn)(void*)GetProcAddress(nt, "RtlGetVersion") : nullptr;
        if (fn && fn(&vi) == 0) return vi.dwBuildNumber;
        return (DWORD)0;
    }();
    return build;
}

UINT dpiForWindow(HWND h) {
    typedef UINT(WINAPI * Fn)(HWND);
    static Fn fn = (Fn)(void*)GetProcAddress(GetModuleHandleW(L"user32.dll"), "GetDpiForWindow");
    if (fn && h) return fn(h);
    HDC dc = GetDC(nullptr);
    const UINT d = (UINT)GetDeviceCaps(dc, LOGPIXELSX);
    ReleaseDC(nullptr, dc);
    return d ? d : 96;
}

UINT dpiForPoint(POINT p) {
    typedef HRESULT(WINAPI * Fn)(HMONITOR, int, UINT*, UINT*);
    static HMODULE shcore = LoadLibraryW(L"shcore.dll");
    static Fn fn = shcore ? (Fn)(void*)GetProcAddress(shcore, "GetDpiForMonitor") : nullptr;
    if (fn) {
        UINT x = 96, y = 96;
        if (SUCCEEDED(fn(MonitorFromPoint(p, MONITOR_DEFAULTTONEAREST), 0, &x, &y))) return x;
    }
    return dpiForWindow(nullptr);
}

void enableDpiAwareness() {
    typedef BOOL(WINAPI * CtxFn)(HANDLE);
    HMODULE u = GetModuleHandleW(L"user32.dll");
    auto ctx = (CtxFn)(void*)GetProcAddress(u, "SetProcessDpiAwarenessContext");
    if (ctx && ctx((HANDLE)-4 /*PER_MONITOR_AWARE_V2*/)) return;
    typedef HRESULT(WINAPI * AwFn)(int);
    HMODULE sh = LoadLibraryW(L"shcore.dll");
    auto aw = sh ? (AwFn)(void*)GetProcAddress(sh, "SetProcessDpiAwareness") : nullptr;
    if (aw && SUCCEEDED(aw(2))) return;
    SetProcessDPIAware();
}

bool transparencyEffectsEnabled() {
    DWORD v = 1, sz = sizeof(v);
    if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                     L"EnableTransparency", RRF_RT_REG_DWORD, nullptr, &v, &sz) == ERROR_SUCCESS)
        return v != 0;
    return true;
}

// Windows 10 fallback blur (undocumented but stable since 2015).
bool accentBlur(HWND hwnd) {
    struct ACCENTPOLICY {
        int nAccentState;
        int nFlags;
        DWORD nColor;
        int nAnimationId;
    };
    struct WINCOMPATTRDATA {
        int nAttribute;
        PVOID pData;
        ULONG ulDataSize;
    };
    typedef BOOL(WINAPI * Fn)(HWND, WINCOMPATTRDATA*);
    auto fn = (Fn)(void*)GetProcAddress(GetModuleHandleW(L"user32.dll"), "SetWindowCompositionAttribute");
    if (!fn) return false;
    ACCENTPOLICY policy = {3 /*ACCENT_ENABLE_BLURBEHIND*/, 0, 0, 0};
    WINCOMPATTRDATA data = {19 /*WCA_ACCENT_POLICY*/, &policy, sizeof(policy)};
    return fn(hwnd, &data) != FALSE;
}

int applyGlass(HWND hwnd) {
    MARGINS m = {-1, -1, -1, -1};
    DwmExtendFrameIntoClientArea(hwnd, &m);
    BOOL dark = TRUE;
    if (FAILED(DwmSetWindowAttribute(hwnd, 20 /*DWMWA_USE_IMMERSIVE_DARK_MODE*/, &dark, sizeof(dark))))
        DwmSetWindowAttribute(hwnd, 19, &dark, sizeof(dark));
    int corner = 2;  // DWMWCP_ROUND
    DwmSetWindowAttribute(hwnd, 33 /*DWMWA_WINDOW_CORNER_PREFERENCE*/, &corner, sizeof(corner));
    COLORREF border = 0xFFFFFFFE;  // DWMWA_COLOR_NONE: we draw our own highlight
    DwmSetWindowAttribute(hwnd, 34 /*DWMWA_BORDER_COLOR*/, &border, sizeof(border));
    if (!transparencyEffectsEnabled()) return 0;
    const DWORD build = windowsBuild();
    if (build >= 22621) {
        int type = 3;  // DWMSBT_TRANSIENTWINDOW (acrylic)
        if (SUCCEEDED(DwmSetWindowAttribute(hwnd, 38 /*DWMWA_SYSTEMBACKDROP_TYPE*/, &type, sizeof(type)))) return 2;
    }
    if (build >= 22000) {
        BOOL mica = TRUE;
        if (SUCCEEDED(DwmSetWindowAttribute(hwnd, 1029 /*DWMWA_MICA_EFFECT*/, &mica, sizeof(mica)))) return 2;
    }
    if (build >= 10240 && accentBlur(hwnd)) return 1;
    return 0;
}

void forceForeground(HWND hwnd) {
    HWND fg = GetForegroundWindow();
    const DWORD me = GetCurrentThreadId();
    const DWORD other = fg ? GetWindowThreadProcessId(fg, nullptr) : 0;
    const bool attach = other && other != me;
    if (attach) AttachThreadInput(me, other, TRUE);
    SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
    BringWindowToTop(hwnd);
    SetForegroundWindow(hwnd);
    SetActiveWindow(hwnd);
    SetFocus(hwnd);
    if (attach) AttachThreadInput(me, other, FALSE);
}

// ------------------------------------------------------------ files
std::wstring appDataDir() {
    wchar_t buf[MAX_PATH] = {};
    std::wstring dir;
    if (SUCCEEDED(SHGetFolderPathW(nullptr, CSIDL_APPDATA, nullptr, 0, buf)))
        dir = buf;
    else if (GetEnvironmentVariableW(L"APPDATA", buf, MAX_PATH))
        dir = buf;
    else
        dir = L".";
    dir += L"\\VortexCrosshair";
    CreateDirectoryW(dir.c_str(), nullptr);
    return dir;
}

bool readFile(const std::wstring& path, std::string& out) {
    HANDLE f = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
    if (f == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER size{};
    GetFileSizeEx(f, &size);
    if (size.QuadPart > (1 << 20)) {
        CloseHandle(f);
        return false;
    }
    out.resize((size_t)size.QuadPart);
    DWORD got = 0;
    const BOOL ok = out.empty() ? TRUE : ReadFile(f, &out[0], (DWORD)out.size(), &got, nullptr);
    CloseHandle(f);
    out.resize(got);
    return ok != FALSE;
}

bool writeFileAtomic(const std::wstring& path, const std::string& data) {
    const std::wstring tmp = path + L".tmp";
    HANDLE f = CreateFileW(tmp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) return false;
    DWORD wrote = 0;
    const BOOL ok = WriteFile(f, data.data(), (DWORD)data.size(), &wrote, nullptr);
    CloseHandle(f);
    if (!ok || wrote != data.size()) return false;
    return MoveFileExW(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != FALSE;
}

void saveNow() {
    if (!g_settingsPath.empty()) writeFileAtomic(g_settingsPath, serializeSettings(g_settings));
    g_savePending = false;
}

// ------------------------------------------------------------ autostart
std::wstring exePath() {
    std::wstring p(MAX_PATH, L'\0');
    for (;;) {
        const DWORD n = GetModuleFileNameW(nullptr, &p[0], (DWORD)p.size());
        if (n < p.size()) {
            p.resize(n);
            return p;
        }
        p.resize(p.size() * 2);
    }
}

bool autostartEnabled() {
    return RegGetValueW(HKEY_CURRENT_USER, kRunKey, kRunValue, RRF_RT_REG_SZ, nullptr, nullptr, nullptr) == ERROR_SUCCESS;
}

void setAutostart(bool on) {
    HKEY k;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_SET_VALUE, &k) != ERROR_SUCCESS) return;
    if (on) {
        const std::wstring v = L"\"" + exePath() + L"\" --tray";
        RegSetValueExW(k, kRunValue, 0, REG_SZ, (const BYTE*)v.c_str(), (DWORD)((v.size() + 1) * sizeof(wchar_t)));
    } else {
        RegDeleteValueW(k, kRunValue);
    }
    RegCloseKey(k);
}

// ------------------------------------------------------------ system cursor hiding
void restoreSystemCursors() { SystemParametersInfoW(SPI_SETCURSORS, 0, nullptr, 0); }

void startCursorGuard() {
    // A tiny watchdog copy of ourselves restores the pointer even if this
    // process is killed while the Windows cursor is hidden.
    if (g_guardProcess) {
        if (WaitForSingleObject(g_guardProcess, 0) == WAIT_TIMEOUT) return;
        CloseHandle(g_guardProcess);
        g_guardProcess = nullptr;
    }
    std::wstring cmd = L"\"" + exePath() + L"\" --cursor-guard " + std::to_wstring(GetCurrentProcessId());
    STARTUPINFOW si{};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi{};
    if (CreateProcessW(nullptr, &cmd[0], nullptr, nullptr, FALSE, CREATE_NO_WINDOW | DETACHED_PROCESS, nullptr, nullptr,
                       &si, &pi)) {
        CloseHandle(pi.hThread);
        g_guardProcess = pi.hProcess;
    }
}

void setCursorsHidden(bool hide) {
    if (hide == g_cursorsHidden) return;
    if (hide) {
        startCursorGuard();
        static const DWORD ids[] = {32512, 32513, 32514, 32515, 32516, 32642, 32643, 32644,
                                    32645, 32646, 32648, 32649, 32650, 32651};
        std::vector<uint8_t> andMask(32 * 4, 0xFF), xorMask(32 * 4, 0x00);
        for (DWORD id : ids) {
            HCURSOR blank = CreateCursor(g_inst, 0, 0, 32, 32, andMask.data(), xorMask.data());
            if (blank) SetSystemCursor(blank, id);  // the system takes ownership
        }
    } else {
        restoreSystemCursors();
    }
    g_cursorsHidden = hide;
}

void updateCursorVisibility() {
    setCursorsHidden(g_settings.hideCursor && g_settings.enabled && !g_menuVisible);
}

LONG WINAPI crashFilter(EXCEPTION_POINTERS*) {
    if (g_cursorsHidden) restoreSystemCursors();
    return EXCEPTION_CONTINUE_SEARCH;
}

// ------------------------------------------------------------ icons
HICON makeIcon(int size) {
    std::vector<uint32_t> px((size_t)size * size, 0);
    Canvas cv;
    cv.attach(px.data(), size, size, size);
    const float s = size / 32.f;
    const Rc tile{0.5f * s, 0.5f * s, size - 1.f * s, size - 1.f * s};
    cv.fillRoundRectGrad(tile, 8.f * s, RGBA{0.17f, 0.16f, 0.21f, 1}, RGBA{0.05f, 0.05f, 0.07f, 1});
    cv.strokeRoundRectGrad(tile, 8.f * s, std::max(1.f, 1.f * s), RGBA{1, 1, 1, 0.28f}, RGBA{1, 1, 1, 0.06f});
    CrosshairStyle st;
    st.scale = size / 62.f;
    st.glow = size >= 24 ? 1.f : 0.6f;
    CrosshairRenderer r;
    r.prepare(st);
    r.render(px.data(), size, size, size, size * 0.5f, size * 0.5f, -0.3175f, st);
    BITMAPV5HEADER bi{};
    bi.bV5Size = sizeof(bi);
    bi.bV5Width = size;
    bi.bV5Height = -size;
    bi.bV5Planes = 1;
    bi.bV5BitCount = 32;
    bi.bV5Compression = BI_BITFIELDS;
    bi.bV5RedMask = 0x00FF0000;
    bi.bV5GreenMask = 0x0000FF00;
    bi.bV5BlueMask = 0x000000FF;
    bi.bV5AlphaMask = 0xFF000000;
    void* bits = nullptr;
    HDC dc = GetDC(nullptr);
    HBITMAP color = CreateDIBSection(dc, (BITMAPINFO*)&bi, DIB_RGB_COLORS, &bits, nullptr, 0);
    ReleaseDC(nullptr, dc);
    if (!color) return nullptr;
    // icons want straight (non premultiplied) alpha
    uint32_t* out = (uint32_t*)bits;
    for (size_t i = 0; i < px.size(); ++i) {
        const uint32_t p = px[i];
        const uint32_t a = p >> 24;
        if (a == 0) {
            out[i] = 0;
            continue;
        }
        auto un = [&](uint32_t c) { return std::min<uint32_t>(255, (c * 255 + a / 2) / a); };
        out[i] = (a << 24) | (un((p >> 16) & 255) << 16) | (un((p >> 8) & 255) << 8) | un(p & 255);
    }
    HBITMAP mask = CreateBitmap(size, size, 1, 1, nullptr);
    ICONINFO ii{};
    ii.fIcon = TRUE;
    ii.hbmMask = mask;
    ii.hbmColor = color;
    HICON icon = CreateIconIndirect(&ii);
    DeleteObject(color);
    DeleteObject(mask);
    return icon;
}

// ------------------------------------------------------------ settings sharing
void publishSettings() {
    AcquireSRWLockExclusive(&g_shared.lock);
    g_shared.settings = g_settings;
    ++g_shared.version;
    ReleaseSRWLockExclusive(&g_shared.lock);
}

void publishMenuState() {
    AcquireSRWLockExclusive(&g_shared.lock);
    g_shared.menuOpen = g_menuVisible;
    if (g_menu) GetWindowRect(g_menu, &g_shared.menuRect);
    ReleaseSRWLockExclusive(&g_shared.lock);
}

void setCapture(int mode) {
    AcquireSRWLockExclusive(&g_shared.lock);
    g_shared.capture = mode;
    ReleaseSRWLockExclusive(&g_shared.lock);
    g_uiDirty = true;
    g_panel.invalidate();
}

int captureMode() {
    AcquireSRWLockShared(&g_shared.lock);
    const int c = g_shared.capture;
    ReleaseSRWLockShared(&g_shared.lock);
    return c;
}

void settingsChanged(const Settings& before) {
    if (before.startWithWindows != g_settings.startWithWindows) setAutostart(g_settings.startWithWindows);
    publishSettings();
    updateCursorVisibility();
    g_savePending = true;
    g_saveDue = nowSec() + 0.6;
}

// ============================================================ overlay thread

bool isModifierKey(int vk) {
    return vk == VK_SHIFT || vk == VK_CONTROL || vk == VK_MENU || vk == VK_LSHIFT || vk == VK_RSHIFT ||
           vk == VK_LCONTROL || vk == VK_RCONTROL || vk == VK_LMENU || vk == VK_RMENU || vk == VK_LWIN || vk == VK_RWIN;
}

bool keyDown(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }

// Generic and left/right variants of the same modifier (pressing Right Shift may
// also report Shift, and on some setups Left Shift, as down).
bool sameFamily(int k, int vk) {
    auto fam = [](int v) {
        if (v == VK_SHIFT || v == VK_LSHIFT || v == VK_RSHIFT) return 1;
        if (v == VK_CONTROL || v == VK_LCONTROL || v == VK_RCONTROL) return 2;
        if (v == VK_MENU || v == VK_LMENU || v == VK_RMENU) return 3;
        if (v == VK_LWIN || v == VK_RWIN) return 4;
        return 0;
    };
    const int a = fam(k), b = fam(vk);
    return a != 0 && a == b;
}

bool anyKeyDown() {
    for (int k = 1; k < 255; ++k)
        if (keyDown(k)) return true;
    return false;
}

// Fires on press for normal keys. For modifier keys (e.g. Right Shift) it fires
// on a clean tap - released quickly without another key being pressed meanwhile -
// so typing capital letters never opens the menu. Keys that were already held
// when the tap started (e.g. W while moving) do not block it.
struct KeyWatch {
    bool down = false, other = false;
    double downAt = 0;
    uint8_t held[256] = {};
    void snapshot(int vk) {
        for (int k = 1; k < 255; ++k) held[k] = (k != vk && !sameFamily(k, vk) && keyDown(k)) ? 1 : 0;
    }
    bool newOtherKey(int vk) {
        for (int k = 1; k < 255; ++k) {
            if (k == vk || sameFamily(k, vk) || held[k]) continue;
            if (keyDown(k)) return true;
        }
        return false;
    }
    bool update(int vk, double t) {
        if (vk <= 0 || vk > 254) {
            down = false;
            return false;
        }
        const bool now = keyDown(vk);
        bool fire = false;
        if (!isModifierKey(vk)) {
            fire = now && !down;
        } else {
            if (now && !down) {
                downAt = t;
                snapshot(vk);
                other = false;
            } else if (now && down) {
                if (!other) other = newOtherKey(vk);
            } else if (!now && down) {
                fire = !other && (t - downAt) < 1.2;
            }
        }
        down = now;
        return fire;
    }
    void sync(int vk) {
        down = vk > 0 && vk < 255 && keyDown(vk);
        other = down;  // a key already held when we start watching must not fire on release
    }
};

struct OverlayDib {
    HDC dc = nullptr;
    HBITMAP bmp = nullptr;
    HGDIOBJ old = nullptr;
    uint32_t* bits = nullptr;
    int size = 0;
    bool ensure(int need) {
        if (need <= size && bmp) return true;
        const int sz = std::max(need, 64);
        if (!dc) {
            HDC screen = GetDC(nullptr);
            dc = CreateCompatibleDC(screen);
            ReleaseDC(nullptr, screen);
        }
        BITMAPINFO bi{};
        bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
        bi.bmiHeader.biWidth = sz;
        bi.bmiHeader.biHeight = -sz;
        bi.bmiHeader.biPlanes = 1;
        bi.bmiHeader.biBitCount = 32;
        bi.bmiHeader.biCompression = BI_RGB;
        void* p = nullptr;
        HBITMAP nb = CreateDIBSection(dc, &bi, DIB_RGB_COLORS, &p, nullptr, 0);
        if (!nb) return false;
        if (bmp) {
            SelectObject(dc, old);
            DeleteObject(bmp);
        }
        bmp = nb;
        old = SelectObject(dc, bmp);
        bits = (uint32_t*)p;
        size = sz;
        return true;
    }
    ~OverlayDib() {
        if (bmp) {
            SelectObject(dc, old);
            DeleteObject(bmp);
        }
        if (dc) DeleteDC(dc);
    }
};

double refreshPeriod() {
    DWM_TIMING_INFO ti{};
    ti.cbSize = sizeof(ti);
    if (SUCCEEDED(DwmGetCompositionTimingInfo(nullptr, &ti)) && ti.rateRefresh.uiNumerator && ti.rateRefresh.uiDenominator) {
        const double hz = (double)ti.rateRefresh.uiNumerator / ti.rateRefresh.uiDenominator;
        if (hz >= 20 && hz <= 1000) return 1.0 / hz;
    }
    DEVMODEW dm{};
    dm.dmSize = sizeof(dm);
    if (EnumDisplaySettingsW(nullptr, ENUM_CURRENT_SETTINGS, &dm) && dm.dmDisplayFrequency > 1)
        return 1.0 / dm.dmDisplayFrequency;
    return 1.0 / 60.0;
}

DWORD WINAPI overlayThread(void*) {
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = g_inst;
    wc.lpszClassName = kOverlayClass;
    RegisterClassExW(&wc);
    HWND hwnd = CreateWindowExW(WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                                kOverlayClass, L"Vortex Crosshair Overlay", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr,
                                g_inst, nullptr);
    if (!hwnd) return 1;

    HANDLE timer = CreateWaitableTimerExW(nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
    if (!timer) timer = CreateWaitableTimerW(nullptr, FALSE, nullptr);

    OverlayDib dib;
    CrosshairRenderer renderer;
    Settings st;
    uint64_t ver = 0;
    bool menuOpen = false;
    RECT menuRect{};
    int capture = 0;
    bool captureArmed = false;
    int suppressKey = 0;  // key just captured: ignore it until released
    double captureDoneAt = 0;
    KeyWatch menuWatch, toggleWatch;

    double period = refreshPeriod();
    double lastPeriodCheck = nowSec();
    double lastT = nowSec();
    double lastTopmost = 0;
    float angle = 0.f, boost = 0.f;
    bool shown = false;
    int affinity = -1;
    int lastSize = 0;
    float lastAngle = 1e9f, lastZoom = -1.f;
    POINT lastDst{INT_MIN, INT_MIN};
    bool forceRender = true;

    while (!g_shared.quit.load()) {
        MSG msg;
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }

        // ---- frame pacing. Wake up shortly before the compositor latches the next frame
        // and only then read the cursor ("late latching"): the crosshair trails the
        // hardware cursor by about one refresh instead of two.
        auto sleepFor = [&](double sec) {
            if (sec <= 0.0002) return;
            if (timer) {
                LARGE_INTEGER due;
                due.QuadPart = -(LONGLONG)(sec * 1e7);
                SetWaitableTimer(timer, &due, 0, nullptr, nullptr, FALSE);
                WaitForSingleObject(timer, 200);
            } else {
                Sleep((DWORD)std::max(1.0, sec * 1000.0));
            }
        };
        bool paced = false;
        {
            DWM_TIMING_INFO ti{};
            ti.cbSize = sizeof(ti);
            if (SUCCEEDED(DwmGetCompositionTimingInfo(nullptr, &ti)) && ti.qpcRefreshPeriod > 0 && ti.qpcVBlank > 0) {
                LARGE_INTEGER f, q;
                QueryPerformanceFrequency(&f);
                QueryPerformanceCounter(&q);
                const double per = (double)ti.qpcRefreshPeriod / (double)f.QuadPart;
                if (per > 0.0015 && per < 0.06) {
                    const double now = (double)q.QuadPart / (double)f.QuadPart;
                    const double vb = (double)ti.qpcVBlank / (double)f.QuadPart;
                    const double margin = std::min(0.005, std::max(0.0025, per * 0.3));
                    double next = vb + per * std::ceil((now - vb) / per);
                    while (next - margin < now + 0.0008) next += per;
                    sleepFor(next - margin - now);
                    period = per;
                    paced = true;
                }
            }
        }
        if (!paced) {
            const double tw = nowSec();
            const HRESULT fr = DwmFlush();
            const double waited = nowSec() - tw;
            if (FAILED(fr) || waited < 0.0015) sleepFor(std::max(0.001, period - waited));
        }

        // ---- settings snapshot
        AcquireSRWLockShared(&g_shared.lock);
        if (g_shared.version != ver) {
            st = g_shared.settings;
            ver = g_shared.version;
            forceRender = true;
        }
        menuOpen = g_shared.menuOpen;
        menuRect = g_shared.menuRect;
        const int newCapture = g_shared.capture;
        ReleaseSRWLockShared(&g_shared.lock);
        if (newCapture != capture) {
            capture = newCapture;
            captureArmed = false;
        }

        const double t = nowSec();
        const float dt = (float)std::min(0.1, std::max(0.0, t - lastT));
        lastT = t;
        if (t - lastPeriodCheck > 2.0) {
            period = refreshPeriod();
            lastPeriodCheck = t;
        }

        // ---- hotkeys / key capture
        if (capture) {
            if (!captureArmed) {
                captureArmed = !anyKeyDown();
            } else {
                for (int k = 3; k < 255; ++k) {
                    if (k == VK_SHIFT || k == VK_CONTROL || k == VK_MENU) continue;
                    if (keyDown(k)) {
                        // clear the shared request ourselves so the next frame does not re-enter capture
                        AcquireSRWLockExclusive(&g_shared.lock);
                        g_shared.capture = 0;
                        ReleaseSRWLockExclusive(&g_shared.lock);
                        PostMessageW(g_shared.notify, WM_APP_KEY_CAPTURED, (WPARAM)k, (LPARAM)capture);
                        captureArmed = false;
                        capture = 0;
                        suppressKey = k;
                        captureDoneAt = t;
                        break;
                    }
                }
            }
        } else if (suppressKey) {
            if (!keyDown(suppressKey) || t - captureDoneAt > 3.0) {
                suppressKey = 0;
                menuWatch.sync(st.menuKey);
                toggleWatch.sync(st.toggleKey);
            }
        } else {
            if (menuWatch.update(st.menuKey, t)) PostMessageW(g_shared.notify, WM_APP_TOGGLE_MENU, 0, 0);
            if (st.toggleKey && st.toggleKey != st.menuKey && toggleWatch.update(st.toggleKey, t))
                PostMessageW(g_shared.notify, WM_APP_TOGGLE_CROSSHAIR, 0, 0);
        }

        // ---- where is the crosshair?
        static POINT lastCursor{0, 0};
        POINT cursor = lastCursor;
        if (GetCursorPos(&cursor)) lastCursor = cursor;
        else cursor = lastCursor;
        POINT p = cursor;
        if (st.position == POS_CENTER) {
            HWND fg = GetForegroundWindow();
            HMONITOR mon = fg ? MonitorFromWindow(fg, MONITOR_DEFAULTTOPRIMARY) : MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
            MONITORINFO mi{};
            mi.cbSize = sizeof(mi);
            if (GetMonitorInfoW(mon, &mi)) {
                p.x = (mi.rcMonitor.left + mi.rcMonitor.right) / 2;
                p.y = (mi.rcMonitor.top + mi.rcMonitor.bottom) / 2;
            }
        }
        p.x += st.offsetX;
        p.y += st.offsetY;
        const bool overMenu = menuOpen && PtInRect(&menuRect, cursor);
        const bool visible = st.enabled && !overMenu;

        // ---- click reaction + spin
        const bool lmb = keyDown(VK_LBUTTON);
        const float target = (st.clickReact != REACT_NONE && lmb && visible) ? 1.f : 0.f;
        const float k = 1.f - std::exp(-(target > boost ? 14.f : 5.f) * dt);
        boost += (target - boost) * k;
        if (std::fabs(target - boost) < 0.001f) boost = target;
        float speed = st.spin ? st.spinSpeed : 0.f;
        if (st.clickReact == REACT_SPIN) speed += (speed > 0.f ? speed : 180.f) * 2.f * boost;
        angle += (st.spinDir == 0 ? 1.f : -1.f) * speed * (kPi / 180.f) * dt;
        angle = std::fmod(angle, 2.f * kPi);
        const float zoom = st.clickReact == REACT_PULSE ? 1.f + 0.18f * boost : 1.f;

        if (!visible) {
            if (shown) {
                ShowWindow(hwnd, SW_HIDE);
                shown = false;
            }
            continue;
        }

        // ---- capture exclusion
        const int wantAffinity = st.hideFromCapture ? 1 : 0;
        if (wantAffinity != affinity) {
            SetWindowDisplayAffinity(hwnd, wantAffinity ? WDA_EXCLUDEFROMCAPTURE : WDA_NONE);
            affinity = wantAffinity;
        }

        // ---- render
        const CrosshairStyle cs = effectiveStyle(st, t);
        renderer.prepare(cs);
        const int half = (int)std::ceil(renderer.extent() * 1.2f) + 2;
        const int size = half * 2;
        if (!dib.ensure(size)) continue;
        const bool needRender = forceRender || st.rainbow || angle != lastAngle || zoom != lastZoom || size != lastSize;
        if (needRender) {
            for (int y = 0; y < size; ++y) std::memset(dib.bits + (size_t)y * dib.size, 0, (size_t)size * 4);
            renderer.render(dib.bits, size, size, dib.size, (float)half, (float)half, angle, cs, 0, 0, size, size, zoom);
            lastAngle = angle;
            lastZoom = zoom;
            lastSize = size;
            forceRender = false;
        }
        POINT dst{p.x - half, p.y - half};
        if (needRender || dst.x != lastDst.x || dst.y != lastDst.y || !shown) {
            SIZE sz{size, size};
            POINT src{0, 0};
            BLENDFUNCTION bf{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
            UpdateLayeredWindow(hwnd, nullptr, &dst, &sz, dib.dc, &src, 0, &bf, ULW_ALPHA);
            lastDst = dst;
        }
        if (!shown) {
            ShowWindow(hwnd, SW_SHOWNOACTIVATE);
            shown = true;
            lastTopmost = 0;
        }
        if (t - lastTopmost > 0.5) {
            SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_NOSENDCHANGING);
            lastTopmost = t;
        }
    }
    if (timer) CloseHandle(timer);
    DestroyWindow(hwnd);
    return 0;
}

// ============================================================ menu window

void ensureMenuSurface(int w, int h) {
    if (g_menuBmp && g_menuW == w && g_menuH == h) return;
    if (!g_menuDC) {
        HDC screen = GetDC(nullptr);
        g_menuDC = CreateCompatibleDC(screen);
        ReleaseDC(nullptr, screen);
    }
    BITMAPINFO bi{};
    bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
    bi.bmiHeader.biWidth = w;
    bi.bmiHeader.biHeight = -h;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    void* bits = nullptr;
    HBITMAP bmp = CreateDIBSection(g_menuDC, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
    if (!bmp) return;
    if (g_menuBmp) {
        SelectObject(g_menuDC, g_menuOldBmp);
        DeleteObject(g_menuBmp);
    }
    g_menuBmp = bmp;
    g_menuOldBmp = SelectObject(g_menuDC, bmp);
    g_menuBits = (uint32_t*)bits;
    g_menuW = w;
    g_menuH = h;
    std::memset(g_menuBits, 0, (size_t)w * h * 4);
    g_canvas.attach(g_menuBits, w, h, w);
    g_panel.invalidate();
}

void presentMenu(const Rc& r) {
    if (!g_menu || !g_menuDC) return;
    const int x0 = std::max(0, (int)std::floor(r.x)), y0 = std::max(0, (int)std::floor(r.y));
    const int x1 = std::min(g_menuW, (int)std::ceil(r.r())), y1 = std::min(g_menuH, (int)std::ceil(r.b()));
    if (x1 <= x0 || y1 <= y0) return;
    GdiFlush();
    HDC dc = GetDC(g_menu);
    BitBlt(dc, x0, y0, x1 - x0, y1 - y0, g_menuDC, x0, y0, SRCCOPY);
    ReleaseDC(g_menu, dc);
}

void setClipboardText(const std::string& s) {
    if (!OpenClipboard(g_menu)) return;
    EmptyClipboard();
    const std::wstring w = toWide(s);
    HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, (w.size() + 1) * sizeof(wchar_t));
    if (mem) {
        void* p = GlobalLock(mem);
        std::memcpy(p, w.c_str(), (w.size() + 1) * sizeof(wchar_t));
        GlobalUnlock(mem);
        if (!SetClipboardData(CF_UNICODETEXT, mem)) GlobalFree(mem);
    }
    CloseClipboard();
}

std::string getClipboardText() {
    std::string out;
    if (!OpenClipboard(g_menu)) return out;
    HANDLE h = GetClipboardData(CF_UNICODETEXT);
    if (h) {
        const wchar_t* p = (const wchar_t*)GlobalLock(h);
        if (p) {
            out = toUtf8(std::wstring(p).substr(0, 64));
            GlobalUnlock(h);
        }
    }
    CloseClipboard();
    return out;
}

void showMenu(bool show);

void runUiFrame() {
    if (!g_menuVisible || !g_menuBits) return;
    const double t = nowSec();
    g_in.time = t;
    g_in.dt = (float)std::min(0.1, std::max(1.0 / 500.0, t - g_lastUiFrame));
    g_lastUiFrame = t;
    g_in.active = GetForegroundWindow() == g_menu;

    AppStatus status;
    status.capturing = captureMode();
    status.glassBackdrop = g_glassLevel > 0;
    status.glassLevel = g_glassLevel;
    const Settings before = g_settings;
    const bool hadTextFocus = g_panel.textFocused();
    UIActions act;
    g_panel.frame(g_canvas, g_scale, g_in, g_settings, act, status);
    presentMenu(g_panel.dirtyRect());

    const bool escapeUnused = g_in.kEscape && !hadTextFocus && status.capturing == 0;
    // consume edge-triggered input
    g_in.mousePressed = g_in.mouseReleased = false;
    g_in.wheel = 0.f;
    g_in.typed.clear();
    g_in.kBack = g_in.kDelete = g_in.kEnter = g_in.kEscape = g_in.kLeft = g_in.kRight = false;
    g_in.kHome = g_in.kEnd = g_in.kSelectAll = g_in.kCopy = g_in.kPaste = false;
    g_in.clipboard.clear();

    g_uiCursor = act.cursor;
    if (act.settingsChanged) settingsChanged(before);
    if (!act.copyText.empty()) setClipboardText(act.copyText);
    if (act.bindKey) setCapture(act.bindKey);
    if (act.cancelBind) setCapture(0);
    if (act.clearToggleKey) {
        const Settings b = g_settings;
        g_settings.toggleKey = 0;
        settingsChanged(b);
        g_panel.invalidate();
    }
    if (act.quit) {
        g_quit = true;
        PostQuitMessage(0);
    }
    if (act.hideMenu || escapeUnused) showMenu(false);
}

// UI scale for a monitor: its DPI scale, shrunk if the panel would not fit the work area.
float fitScale(float dpiScale, HMONITOR mon) {
    MONITORINFO mi{};
    mi.cbSize = sizeof(mi);
    if (!GetMonitorInfoW(mon, &mi)) return dpiScale;
    const float ww = (float)(mi.rcWork.right - mi.rcWork.left), wh = (float)(mi.rcWork.bottom - mi.rcWork.top);
    const float fit = std::min(ww * 0.96f / SettingsPanel::kWidth, wh * 0.96f / SettingsPanel::kHeight);
    return std::max(0.5f, std::min(dpiScale, fit));
}

void placeMenu() {
    POINT cur{};
    GetCursorPos(&cur);
    RECT wr{};
    bool keep = false;
    if (g_menuPlaced && GetWindowRect(g_menu, &wr)) {
        POINT c{(wr.left + wr.right) / 2, (wr.top + wr.bottom) / 2};
        HMONITOR m = MonitorFromPoint(c, MONITOR_DEFAULTTONULL);
        keep = m != nullptr;
    }
    const UINT dpi = keep ? dpiForWindow(g_menu) : dpiForPoint(cur);
    const HMONITOR mon = keep ? MonitorFromWindow(g_menu, MONITOR_DEFAULTTONEAREST) : MonitorFromPoint(cur, MONITOR_DEFAULTTONEAREST);
    g_scale = fitScale(dpi / 96.f, mon);
    const int w = (int)std::ceil(SettingsPanel::kWidth * g_scale), h = (int)std::ceil(SettingsPanel::kHeight * g_scale);
    int x, y;
    if (keep) {
        x = wr.left;
        y = wr.top;
    } else {
        MONITORINFO mi{};
        mi.cbSize = sizeof(mi);
        GetMonitorInfoW(MonitorFromPoint(cur, MONITOR_DEFAULTTONEAREST), &mi);
        x = (mi.rcWork.left + mi.rcWork.right - w) / 2;
        y = (mi.rcWork.top + mi.rcWork.bottom - h) / 2;
        g_menuPlaced = true;
    }
    ensureMenuSurface(w, h);
    SetWindowPos(g_menu, HWND_TOPMOST, x, y, w, h, SWP_NOACTIVATE);
    // a DPI change during the move may have rescaled us
    const float s2 = fitScale(dpiForWindow(g_menu) / 96.f, MonitorFromWindow(g_menu, MONITOR_DEFAULTTONEAREST));
    if (std::fabs(s2 - g_scale) > 0.01f) {
        g_scale = s2;
        const int w2 = (int)std::ceil(SettingsPanel::kWidth * g_scale), h2 = (int)std::ceil(SettingsPanel::kHeight * g_scale);
        ensureMenuSurface(w2, h2);
        SetWindowPos(g_menu, nullptr, 0, 0, w2, h2, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    }
}

void showMenu(bool show) {
    if (!g_menu || show == g_menuVisible) return;
    if (show) {
        HWND fg = GetForegroundWindow();
        g_prevForeground = (fg && fg != g_menu) ? fg : nullptr;
        placeMenu();
        g_menuVisible = true;
        g_panel.invalidate();
        g_panel.resetInteraction();
        g_in = UIInput();
        POINT cp;
        GetCursorPos(&cp);
        ScreenToClient(g_menu, &cp);
        g_in.mx = (float)cp.x;
        g_in.my = (float)cp.y;
        g_lastUiFrame = nowSec();
        runUiFrame();  // draw before the window appears (no flash)
        BOOL cloak = TRUE;
        DwmSetWindowAttribute(g_menu, 13 /*DWMWA_CLOAK*/, &cloak, sizeof(cloak));
        ShowWindow(g_menu, SW_SHOW);
        UpdateWindow(g_menu);
        cloak = FALSE;
        DwmSetWindowAttribute(g_menu, 13 /*DWMWA_CLOAK*/, &cloak, sizeof(cloak));
        forceForeground(g_menu);
        g_uiDirty = true;
    } else {
        g_menuVisible = false;
        if (captureMode()) setCapture(0);
        if (GetCapture() == g_menu) ReleaseCapture();
        ShowWindow(g_menu, SW_HIDE);
        if (g_prevForeground && IsWindow(g_prevForeground)) SetForegroundWindow(g_prevForeground);
        g_prevForeground = nullptr;
        if (g_savePending) saveNow();
    }
    publishMenuState();
    updateCursorVisibility();
}

void appendUtf8(std::string& s, uint32_t cp) {
    if (cp < 0x80) {
        s += (char)cp;
    } else if (cp < 0x800) {
        s += (char)(0xC0 | (cp >> 6));
        s += (char)(0x80 | (cp & 0x3F));
    } else {
        s += (char)(0xE0 | (cp >> 12));
        s += (char)(0x80 | ((cp >> 6) & 0x3F));
        s += (char)(0x80 | (cp & 0x3F));
    }
}

LRESULT CALLBACK menuProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    switch (m) {
        case WM_NCCALCSIZE:
            if (w) return 0;
            break;
        case WM_NCHITTEST: {
            POINT p{GET_X_LPARAM(l), GET_Y_LPARAM(l)};
            ScreenToClient(h, &p);
            return g_panel.dragArea((float)p.x, (float)p.y) ? HTCAPTION : HTCLIENT;
        }
        case WM_NCACTIVATE:
            return DefWindowProcW(h, m, w, -1);
        case WM_ACTIVATE:
            g_uiDirty = true;
            break;
        case WM_ERASEBKGND:
            return 1;
        case WM_PAINT: {
            PAINTSTRUCT ps;
            HDC dc = BeginPaint(h, &ps);
            if (g_menuDC) BitBlt(dc, 0, 0, g_menuW, g_menuH, g_menuDC, 0, 0, SRCCOPY);
            EndPaint(h, &ps);
            return 0;
        }
        case WM_MOVE:
            publishMenuState();
            break;
        case WM_ENTERSIZEMOVE:
            SetTimer(h, 1, 16, nullptr);  // keep animating inside the modal drag loop
            break;
        case WM_EXITSIZEMOVE:
            KillTimer(h, 1);
            publishMenuState();
            break;
        case WM_TIMER:
            if (w == 1) {
                runUiFrame();
                return 0;
            }
            break;
        case WM_WINDOWPOSCHANGING: {
            // the layout is fixed-size: never let snapping or the shell resize us
            WINDOWPOS* wp = (WINDOWPOS*)l;
            if (!(wp->flags & SWP_NOSIZE) && g_menuW > 0 && g_menuH > 0) {
                wp->cx = g_menuW;
                wp->cy = g_menuH;
            }
            break;
        }
        case WM_SYSCOMMAND:
            if ((w & 0xFFF0) == SC_MAXIMIZE || (w & 0xFFF0) == SC_SIZE) return 0;
            if ((w & 0xFFF0) == SC_MINIMIZE || (w & 0xFFF0) == SC_CLOSE) {
                showMenu(false);
                return 0;
            }
            break;
        case WM_DPICHANGED: {
            const RECT* r = (const RECT*)l;
            g_scale = fitScale(HIWORD(w) / 96.f, MonitorFromRect(r, MONITOR_DEFAULTTONEAREST));
            const int nw = (int)std::ceil(SettingsPanel::kWidth * g_scale), nh = (int)std::ceil(SettingsPanel::kHeight * g_scale);
            ensureMenuSurface(nw, nh);
            SetWindowPos(h, nullptr, r->left, r->top, nw, nh, SWP_NOZORDER | SWP_NOACTIVATE);
            g_panel.invalidate();
            g_uiDirty = true;
            publishMenuState();
            return 0;
        }
        case WM_MOUSEMOVE:
            g_in.mx = (float)GET_X_LPARAM(l);
            g_in.my = (float)GET_Y_LPARAM(l);
            if (!g_trackingMouse) {
                TRACKMOUSEEVENT tme{sizeof(tme), TME_LEAVE, h, 0};
                TrackMouseEvent(&tme);
                g_trackingMouse = true;
            }
            g_uiDirty = true;
            return 0;
        case WM_MOUSELEAVE:
            g_trackingMouse = false;
            if (!g_in.mouseDown) {
                g_in.mx = g_in.my = -1e6f;
                g_uiDirty = true;
            }
            return 0;
        case WM_LBUTTONDOWN:
        case WM_LBUTTONDBLCLK:
            SetCapture(h);
            g_in.mx = (float)GET_X_LPARAM(l);
            g_in.my = (float)GET_Y_LPARAM(l);
            g_in.mouseDown = true;
            g_in.mousePressed = true;
            g_uiDirty = true;
            runUiFrame();  // immediate response
            return 0;
        case WM_LBUTTONUP:
            if (GetCapture() == h) ReleaseCapture();
            g_in.mx = (float)GET_X_LPARAM(l);
            g_in.my = (float)GET_Y_LPARAM(l);
            g_in.mouseDown = false;
            g_in.mouseReleased = true;
            g_uiDirty = true;
            runUiFrame();
            return 0;
        case WM_CAPTURECHANGED:
            if (g_in.mouseDown) {
                g_in.mouseDown = false;
                g_in.mouseReleased = true;
                g_uiDirty = true;
            }
            break;
        case WM_MOUSEWHEEL:
            g_in.wheel += GET_WHEEL_DELTA_WPARAM(w) / 120.f;
            g_uiDirty = true;
            return 0;
        case WM_CHAR:
            if (w >= 32 && w != 127) {
                appendUtf8(g_in.typed, (uint32_t)w);
                g_uiDirty = true;
            }
            return 0;
        case WM_KEYDOWN:
        case WM_SYSKEYDOWN: {
            const bool ctrl = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
            switch (w) {
                case VK_BACK: g_in.kBack = true; break;
                case VK_DELETE: g_in.kDelete = true; break;
                case VK_RETURN: g_in.kEnter = true; break;
                case VK_ESCAPE: g_in.kEscape = true; break;
                case VK_LEFT: g_in.kLeft = true; break;
                case VK_RIGHT: g_in.kRight = true; break;
                case VK_HOME: g_in.kHome = true; break;
                case VK_END: g_in.kEnd = true; break;
                case 'A': if (ctrl) g_in.kSelectAll = true; break;
                case 'C': if (ctrl) g_in.kCopy = true; break;
                case 'V':
                    if (ctrl) {
                        g_in.kPaste = true;
                        g_in.clipboard = getClipboardText();
                    }
                    break;
                default: break;
            }
            g_uiDirty = true;
            if (m == WM_SYSKEYDOWN) break;
            return 0;
        }
        case WM_SETCURSOR:
            if (LOWORD(l) == HTCLIENT) {
                LPCWSTR id = g_uiCursor == CURSOR_HAND ? IDC_HAND : (g_uiCursor == CURSOR_IBEAM ? IDC_IBEAM : IDC_ARROW);
                SetCursor(LoadCursorW(nullptr, id));
                return TRUE;
            }
            break;
        case WM_CLOSE:
            showMenu(false);
            return 0;
        default:
            break;
    }
    return DefWindowProcW(h, m, w, l);
}

// ============================================================ tray + main window

void addTrayIcon() {
    g_nid = NOTIFYICONDATAW{};
    g_nid.cbSize = sizeof(g_nid);
    g_nid.hWnd = g_main;
    g_nid.uID = 1;
    g_nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    g_nid.uCallbackMessage = WM_APP_TRAY;
    g_nid.hIcon = g_iconSmall;
    const std::wstring tip = L"Vortex Crosshair \x2014 " + toWide(keyName(g_settings.menuKey)) + L" opens the menu";
    wcsncpy(g_nid.szTip, tip.c_str(), ARRAYSIZE(g_nid.szTip) - 1);
    Shell_NotifyIconW(NIM_ADD, &g_nid);
    g_nid.uVersion = NOTIFYICON_VERSION_4;
    g_trayV4 = Shell_NotifyIconW(NIM_SETVERSION, &g_nid) != FALSE;
}

void showBalloon(const wchar_t* title, const wchar_t* textMsg) {
    NOTIFYICONDATAW n = g_nid;
    n.uFlags = NIF_INFO;
    wcsncpy(n.szInfoTitle, title, ARRAYSIZE(n.szInfoTitle) - 1);
    wcsncpy(n.szInfo, textMsg, ARRAYSIZE(n.szInfo) - 1);
    n.dwInfoFlags = NIIF_USER | NIIF_LARGE_ICON;
    n.hBalloonIcon = g_iconBig;
    Shell_NotifyIconW(NIM_MODIFY, &n);
}

void toggleCrosshair() {
    const Settings b = g_settings;
    g_settings.enabled = !g_settings.enabled;
    settingsChanged(b);
    g_panel.invalidate();
    g_uiDirty = true;
}

void trayMenu() {
    HMENU menu = CreatePopupMenu();
    const std::wstring open = L"Open menu\t" + toWide(keyName(g_settings.menuKey));
    AppendMenuW(menu, MF_STRING, TRAY_OPEN, open.c_str());
    AppendMenuW(menu, MF_STRING | (g_settings.enabled ? MF_CHECKED : 0), TRAY_TOGGLE, L"Show crosshair");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, TRAY_QUIT, L"Quit Vortex");
    SetMenuDefaultItem(menu, TRAY_OPEN, FALSE);
    POINT p;
    GetCursorPos(&p);
    SetForegroundWindow(g_main);
    const int cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY, p.x, p.y, 0, g_main, nullptr);
    DestroyMenu(menu);
    PostMessageW(g_main, WM_NULL, 0, 0);
    if (cmd == TRAY_OPEN) showMenu(true);
    if (cmd == TRAY_TOGGLE) toggleCrosshair();
    if (cmd == TRAY_QUIT) {
        g_quit = true;
        PostQuitMessage(0);
    }
}

LRESULT CALLBACK mainProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == g_taskbarCreated && g_taskbarCreated) {
        addTrayIcon();
        return 0;
    }
    switch (m) {
        case WM_APP_TRAY: {
            const UINT ev = LOWORD(l);
            if (g_trayV4) {
                if (ev == NIN_SELECT || ev == NIN_KEYSELECT) showMenu(!g_menuVisible);
                if (ev == WM_CONTEXTMENU) trayMenu();
            } else {
                if (ev == WM_LBUTTONUP) showMenu(!g_menuVisible);
                if (ev == WM_RBUTTONUP) trayMenu();
            }
            return 0;
        }
        case WM_APP_TOGGLE_MENU:
            showMenu(!g_menuVisible);
            return 0;
        case WM_APP_SHOW_MENU:
            showMenu(true);
            return 0;
        case WM_APP_TOGGLE_CROSSHAIR:
            toggleCrosshair();
            return 0;
        case WM_APP_KEY_CAPTURED: {
            const int vk = (int)w, mode = (int)l;
            setCapture(0);
            if (vk == VK_ESCAPE) return 0;
            const Settings b = g_settings;
            if (mode == 1) {
                g_settings.menuKey = vk;
                if (g_settings.toggleKey == vk) g_settings.toggleKey = 0;
            } else if (mode == 2 && vk != g_settings.menuKey) {
                g_settings.toggleKey = vk;
            }
            settingsChanged(b);
            if (b.menuKey != g_settings.menuKey) {
                const std::wstring tip = L"Vortex Crosshair \x2014 " + toWide(keyName(g_settings.menuKey)) + L" opens the menu";
                wcsncpy(g_nid.szTip, tip.c_str(), ARRAYSIZE(g_nid.szTip) - 1);
                g_nid.uFlags = NIF_TIP;
                Shell_NotifyIconW(NIM_MODIFY, &g_nid);
            }
            g_panel.invalidate();
            g_uiDirty = true;
            return 0;
        }
        case WM_QUERYENDSESSION:
            return TRUE;
        case WM_ENDSESSION:
            if (w) {
                if (g_cursorsHidden) restoreSystemCursors();
                saveNow();
            }
            return 0;
        case WM_DESTROY:
            return 0;
        default:
            break;
    }
    return DefWindowProcW(h, m, w, l);
}

int cursorGuardMain(DWORD pid) {
    HANDLE p = OpenProcess(SYNCHRONIZE, FALSE, pid);
    if (p) {
        WaitForSingleObject(p, INFINITE);
        CloseHandle(p);
    }
    restoreSystemCursors();
    return 0;
}

}  // namespace

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int) {
    g_inst = inst;
    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    bool trayStart = false, openMenu = false;
    for (int i = 1; argv && i < argc; ++i) {
        if (wcscmp(argv[i], L"--cursor-guard") == 0 && i + 1 < argc) return cursorGuardMain((DWORD)_wtoi(argv[i + 1]));
        if (wcscmp(argv[i], L"--tray") == 0) trayStart = true;
        if (wcscmp(argv[i], L"--menu") == 0) openMenu = true;
    }
    if (argv) LocalFree(argv);

    enableDpiAwareness();

    HANDLE mutex = CreateMutexW(nullptr, TRUE, kMutexName);
    if (mutex && GetLastError() == ERROR_ALREADY_EXISTS) {
        HWND other = FindWindowW(kMainClass, nullptr);
        if (other) PostMessageW(other, WM_APP_SHOW_MENU, 0, 0);
        return 0;
    }
    SetUnhandledExceptionFilter(crashFilter);

    // settings
    const std::wstring dir = appDataDir();
    g_settingsPath = dir + L"\\settings.ini";
    std::string iniText;
    const bool firstRun = !readFile(g_settingsPath, iniText);
    if (!firstRun) parseSettings(iniText, g_settings);
    if (g_settings.hideCursor) restoreSystemCursors();  // recover from an unclean exit
    g_settings.startWithWindows = autostartEnabled();
    if (g_settings.startWithWindows) setAutostart(true);  // refresh path if the exe moved
    g_shared.settings = g_settings;

    g_iconBig = makeIcon(GetSystemMetrics(SM_CXICON) > 0 ? std::max(32, GetSystemMetrics(SM_CXICON)) : 32);
    g_iconSmall = makeIcon(GetSystemMetrics(SM_CXSMICON) > 0 ? std::max(16, GetSystemMetrics(SM_CXSMICON)) : 16);

    // main (hidden) window: tray + IPC
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = mainProc;
    wc.hInstance = inst;
    wc.lpszClassName = kMainClass;
    wc.hIcon = g_iconBig;
    RegisterClassExW(&wc);
    g_main = CreateWindowExW(WS_EX_TOOLWINDOW, kMainClass, kAppTitle, WS_POPUP, 0, 0, 0, 0, nullptr, nullptr, inst, nullptr);
    g_shared.notify = g_main;
    g_taskbarCreated = RegisterWindowMessageW(L"TaskbarCreated");

    // menu window
    WNDCLASSEXW mc{};
    mc.cbSize = sizeof(mc);
    mc.lpfnWndProc = menuProc;
    mc.hInstance = inst;
    mc.lpszClassName = kMenuClass;
    mc.hIcon = g_iconBig;
    mc.hIconSm = g_iconSmall;
    mc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    RegisterClassExW(&mc);
    // WS_CAPTION keeps the DWM shadow and Windows 11 rounded corners; no WS_SYSMENU so DWM
    // never paints caption buttons onto our full-window glass.
    g_menu = CreateWindowExW(WS_EX_TOPMOST | WS_EX_APPWINDOW, kMenuClass, kAppTitle, WS_POPUP | WS_CAPTION,
                             CW_USEDEFAULT, CW_USEDEFAULT,
                             (int)SettingsPanel::kWidth, (int)SettingsPanel::kHeight, nullptr, nullptr, inst, nullptr);
    if (g_menu) {
        SendMessageW(g_menu, WM_SETICON, ICON_BIG, (LPARAM)g_iconBig);
        SendMessageW(g_menu, WM_SETICON, ICON_SMALL, (LPARAM)g_iconSmall);
        g_glassLevel = applyGlass(g_menu);
        SetWindowPos(g_menu, nullptr, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED | SWP_NOACTIVATE);
    }
    vx::text().init();

    addTrayIcon();
    HANDLE overlay = CreateThread(nullptr, 0, overlayThread, nullptr, 0, nullptr);
    if (overlay) SetThreadPriority(overlay, THREAD_PRIORITY_ABOVE_NORMAL);

    updateCursorVisibility();
    if (!trayStart || openMenu) showMenu(true);
    if (firstRun) {
        const std::wstring msg = L"Your crosshair is live. Press " + toWide(keyName(g_settings.menuKey)) +
                                 L" anytime to open the menu.";
        showBalloon(L"Vortex Crosshair is running", msg.c_str());
        g_savePending = true;
        g_saveDue = nowSec() + 1.0;
    }

    // ---- main loop: messages + UI frames paced to the display
    MSG msg;
    while (!g_quit) {
        const double now = nowSec();
        DWORD timeout = INFINITE;
        const bool wantFrame = g_menuVisible && (g_uiDirty || g_panel.animating());
        const double frameGap = g_uiDirty ? 1.0 / 120.0 : 1.0 / 60.0;
        if (wantFrame) {
            const double wait = g_lastUiFrame + frameGap - now;
            timeout = wait > 0 ? (DWORD)std::ceil(wait * 1000.0) : 0;
        }
        if (g_savePending) {
            const double wait = g_saveDue - now;
            timeout = std::min<DWORD>(timeout, wait > 0 ? (DWORD)std::ceil(wait * 1000.0) : 0);
        }
        MsgWaitForMultipleObjectsEx(0, nullptr, timeout, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
            if (msg.message == WM_QUIT) {
                g_quit = true;
                break;
            }
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        if (g_quit) break;
        const double t = nowSec();
        if (g_menuVisible && (g_uiDirty || g_panel.animating()) && t - g_lastUiFrame >= frameGap * 0.9) {
            g_uiDirty = false;
            runUiFrame();
        }
        if (g_savePending && t >= g_saveDue) saveNow();
    }

    // ---- shutdown
    g_shared.quit = true;
    if (overlay) {
        WaitForSingleObject(overlay, 2000);
        CloseHandle(overlay);
    }
    if (g_cursorsHidden) restoreSystemCursors();
    g_cursorsHidden = false;
    saveNow();
    Shell_NotifyIconW(NIM_DELETE, &g_nid);
    if (g_menu) DestroyWindow(g_menu);
    if (g_main) DestroyWindow(g_main);
    if (g_guardProcess) CloseHandle(g_guardProcess);
    if (mutex) CloseHandle(mutex);
    return 0;
}
