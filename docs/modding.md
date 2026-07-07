# Dusklight Mod API

Mods are distributed as `.dusk` files: zip archives containing a `mod.json` manifest and, optionally, compiled code libraries and resources.

Everything a mod does goes through **services**: small, versioned C APIs. Dusklight provides built-in services, and mods can define their own to talk to each other.

## Table of Contents

1. [Getting Started](#getting-started)
2. [mod.json](#modjson)
3. [Anatomy of a Code Mod](#anatomy-of-a-code-mod)
4. [Services](#services)
5. [Built-in Services](#built-in-services)
6. [Runtime Lifecycle](#runtime-lifecycle)
7. [Error Handling](#error-handling)
8. [Advanced: Exporting Services](#advanced-exporting-services)

---

## Getting Started

Fork the [mod template](../tools/mod_template/), a self-contained CMake project that uses the Dusklight mod SDK:

```
my_mod/
├── CMakeLists.txt
├── mod.json
├── src/mod.cpp
└── res/       (optional bundled resources)
```

**CMakeLists.txt:**

```cmake
cmake_minimum_required(VERSION 3.25)
project(my_mod CXX)

set(DUSKLIGHT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/dusklight" CACHE PATH "Path to dusklight source root")
add_subdirectory("${DUSKLIGHT_DIR}/sdk" dusklight-sdk EXCLUDE_FROM_ALL)

add_mod(my_mod
    SOURCES  src/mod.cpp
    MOD_JSON mod.json
    RES_DIR  res        # optional
)
```

Building produces `my_mod.dusk` in `build/<preset>/mods/` (configurable via the `DUSK_MODS_OUTPUT_DIR` cache variable). Copy it into the game's mods folder and launch:

- Windows: `%APPDATA%\TwilitRealm\Dusklight\mods`
- Linux: `~/.local/share/TwilitRealm/Dusklight/mods`
- macOS: `~/Library/Application Support/TwilitRealm/Dusklight/mods`

You can also pass `--mods <dir>` on the command line, which is handy during development. Mods will load from there instead of the user directory above.

---

## mod.json

```json
{
    "id":          "com.example.my_mod",
    "name":        "My Mod",
    "version":     "1.0.0",
    "author":      "Your Name",
    "description": "A short description shown in the mod manager.",
    "icon":        "res/my_icon.png",
    "banner":      "res/my_banner.png"
}
```

`id` is required: a unique, stable identifier (reverse-DNS style; periods, underscores, and alphanumerics). Everything else is optional but recommended.

`icon` and `banner` are bundle-relative paths to PNG images for the in-game mod manager: the square icon (e.g. 512x512), the banner (roughly 3.5:1).
Both keys are optional; if omitted, `res/icon.png` and `res/banner.png` are used automatically when present.

---

## Anatomy of a Code Mod

```cpp
#include "mods/service.hpp"
#include "mods/svc/log.h"

DEFINE_MOD();                          // once, in exactly one translation unit
IMPORT_SERVICE(LogService, svc_log);   // resolved by the loader before mod_initialize

extern "C" {

MOD_EXPORT ModResult mod_initialize(ModError* error) {
    svc_log->info(mod_ctx, "hello from my_mod");
    return MOD_OK;
}

MOD_EXPORT ModResult mod_update(ModError* error) {   // called every frame
    return MOD_OK;
}

MOD_EXPORT ModResult mod_shutdown(ModError* error) {
    return MOD_OK;
}
}
```

All three lifecycle exports are required. `mod_ctx` is your mod's identity token, set by the loader before `mod_initialize` runs. Pass it as the first argument to every service call.

---

## Services

A service is a struct of C function pointers with a version header. You declare what you use at file scope, and the loader resolves it before your mod initializes:

```cpp
IMPORT_SERVICE(LogService, svc_log);                    // required, any minor version
IMPORT_SERVICE_VERSION(LogService, svc_log, 2);         // required, minor version >= 2
IMPORT_OPTIONAL_SERVICE(SomeService, svc_maybe);        // may be null
```

The rules (see `include/mods/api.h` for the full contract):

- **A required import is guaranteed valid.** If the service is missing or too old, the mod fails to load with a clear error. No need to null check at call sites.
- **Anything at or below the minor version you imported can be called unconditionally.**
- Optional imports may be null; check once in `mod_initialize`.
- Fields newer than your imported minor must be gated behind `SERVICE_HAS(service, ServiceType, field)` plus a null check.

Service versions follow one rule: a **major** bump is a breaking change (treated as a different service entirely), a **minor** bump only appends functions.

---

## Built-in Services

### LogService (`mods/svc/log.h`)

```cpp
IMPORT_SERVICE(LogService, svc_log);

svc_log->info(mod_ctx, "spawned the thing");
svc_log->warn(mod_ctx, "that looks wrong");
svc_log->error(mod_ctx, "very bad");
svc_log->write(mod_ctx, LOG_LEVEL_DEBUG, "verbose details");
```

Messages appear in the console prefixed with your mod ID. Messages are plain strings: use `snprintf` or `fmt::format` for formatting.

### HostService (`mods/svc/host.h`)

Mod metadata and runtime interaction with the loader:

```cpp
IMPORT_SERVICE(HostService, svc_host);

const char* id  = svc_host->mod_id(mod_ctx);
const char* dir = svc_host->mod_dir(mod_ctx);  // writable per-mod directory
svc_host->fail(mod_ctx, MOD_ERROR, "something unrecoverable happened");  // disables the mod
```

`get_service`/`publish_service` provide dynamic service lookup; see [Advanced](#advanced-exporting-services).

---

## Runtime Lifecycle

Mods can be disabled, re-enabled, and reloaded at runtime without restarting the game (the enabled state persists as the `mod.<escaped id>.enabled` config var). Write your mod assuming this happens:

- **Disable** calls `mod_shutdown`, removes your services, and unloads your library.
- **Enable** and **Reload** load a *fresh copy* of your library, imports are re-resolved, and `mod_initialize` runs again. You never see a second `mod_initialize` on the same image, so just make `mod_shutdown` release anything the loader doesn't manage for you (threads, files, game-side state you mutated).
- **Reload** additionally re-reads the `.dusk` from disk, picking up a rebuilt library and changed assets. This is the fast iteration loop during development: rebuild, click Reload.

**Dependents restart too.** Disabling or reloading a mod that exports services shuts down the mods importing them first (in reverse dependency order) and brings them back afterward. A mod whose *required* provider is disabled stays suspended and resumes automatically when the provider returns. Mods with an *optional* import of a disabled provider restart with that import null.

---

## Error Handling

Service calls report failure through `ModResult` return values (`MOD_OK`, `MOD_UNAVAILABLE`, `MOD_INVALID_ARGUMENT`, ...). Lifecycle exports additionally receive a `ModError*`: fill it (e.g. with `dusk::mods::set_error(error, code, "message")`) and return the code, and the loader disables the mod and shows the message to the user.

```cpp
MOD_EXPORT ModResult mod_initialize(ModError* error) {
    if (!load_my_data()) {
        return dusk::mods::set_error(error, MOD_ERROR, "failed to load data");
    }
    return MOD_OK;
}
```

Throwing exceptions out of lifecycle functions also disables the mod (they are caught by the loader), but prefer explicit results.

---

## Advanced: Exporting Services

Mods can provide services to other mods. Define the interface in a header both mods share:

```cpp
// my_mod_api.h
#include "mods/api.h"

#define MY_MOD_SERVICE_ID "com.example.my_mod.api"
#define MY_MOD_SERVICE_MAJOR 1u
#define MY_MOD_SERVICE_MINOR 0u

typedef struct MyModService {
    ServiceHeader header;
    ModResult (*do_thing)(ModContext* ctx, int value);
} MyModService;

#ifdef __cplusplus
#include "mods/service.hpp"
template <>
struct dusk::mods::ServiceTraits<MyModService> {
    static constexpr const char* id = MY_MOD_SERVICE_ID;
    static constexpr uint16_t major_version = MY_MOD_SERVICE_MAJOR;
};
#endif
```

**Provider:**

```cpp
ModResult do_thing(ModContext* ctx, int value) { ... }

constexpr MyModService g_service{
    .header = SERVICE_HEADER(MyModService, MY_MOD_SERVICE_MAJOR, MY_MOD_SERVICE_MINOR),
    .do_thing = do_thing,
};
EXPORT_SERVICE(g_service);
```

**Consumer:**

```cpp
IMPORT_SERVICE(MyModService, svc_my_mod);
// or IMPORT_OPTIONAL_SERVICE if the dependency is optional

svc_my_mod->do_thing(mod_ctx, 42);
```

The loader registers all exports before resolving any imports, so declaration order between mods doesn't matter. Note that the `ctx` a provider receives identifies the *calling* mod.

### Dependencies between mods

Service imports are also dependency declarations: the loader initializes mods in dependency order, so by the time your `mod_initialize` runs, every mod you import services from (required *or* optional) has already finished its own `mod_initialize`. This includes deferred services: a service the provider publishes during its initialization resolves into your import slot just like a static export.

Consequences of that contract:

- If a provider fails to load, every mod that *requires* one of its services is disabled too, with an error naming the provider. Optional imports of a failed provider simply resolve to `NULL`.
- Mods whose **required** imports form a cycle all fail to load. If the cycle runs through an **optional** import, the loader breaks it there: the optional import still resolves, but its provider may not be initialized yet when you run.
- `svc_host->get_service(...)` is outside this system. It sees whatever is published at call time and gives no initialization-order guarantee, which also makes it the escape hatch for intentionally cyclic designs.

Mods shut down in reverse initialization order, so services you import remain safe to call from `mod_shutdown`.

Rules for providers:

- Service IDs are global and use reverse-DNS names (e.g. `com.mydomain.mod.service`)
- Every function pointer covered by your declared minor version must be populated.
- Within a major version, only append fields; never reorder, remove, or repurpose them. Breaking changes require a major bump (which is, in effect, a new service).
- Only one provider per `(id, major)` pair may be registered; duplicates are load errors.

For services whose construction can't happen at static-init time, declare the export with `EXPORT_DEFERRED_SERVICE(...)` and publish the pointer later via `svc_host->publish_service(...)`. Consumers can fetch services dynamically with `svc_host->get_service(...)`; prefer manifest imports whenever possible, since they give the loader dependency information and fail fast with good errors.
