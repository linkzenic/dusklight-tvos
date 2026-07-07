#pragma once

#include "mods/api.h"

/*
 * The host service: the calling mod's identity and its runtime interface to the loader.
 * Always available; every other service can be reached from it.
 */

#define HOST_SERVICE_ID "dev.twilitrealm.dusklight.host"
#define HOST_SERVICE_MAJOR 1u
#define HOST_SERVICE_MINOR 0u

typedef struct HostService {
    ServiceHeader header;

    /*
     * Look up a service by id at call time. Unlike a manifest import, this sees whatever is
     * currently published and carries no initialization-order guarantee (see mods/api.h).
     * MOD_UNAVAILABLE if no matching service is published; *out_service is null on failure.
     */
    ModResult (*get_service)(ModContext* ctx, const char* service_id, uint16_t major_version,
        uint16_t min_minor_version, const void** out_service);

    /*
     * Publish a service the calling mod declared as a deferred export in its manifest.
     * Must happen during mod_initialize so importers can resolve it; `service` must stay
     * valid until the mod shuts down.
     */
    ModResult (*publish_service)(
        ModContext* ctx, const char* service_id, uint16_t major_version, const void* service);

    /*
     * Report an unrecoverable failure. The calling mod's services stop resolving immediately
     * and the loader fully disables it at the next safe point; `message` is shown to the user.
     * Safe to call from any mod callback.
     */
    void (*fail)(ModContext* ctx, ModResult code, const char* message);

    /*
     * The calling mod's manifest metadata. Returned strings remain valid while the mod is
     * loaded.
     */
    const char* (*mod_id)(ModContext* ctx);
    const char* (*mod_name)(ModContext* ctx);
    const char* (*mod_version)(ModContext* ctx);

    /*
     * A writable scratch directory reserved for the calling mod. Contents survive disable
     * and reload within a session, but the directory is wiped at game startup.
     */
    const char* (*mod_dir)(ModContext* ctx);
} HostService;

#ifdef __cplusplus
#include "mods/service.hpp"

template <>
struct dusk::mods::ServiceTraits<HostService> {
    static constexpr const char* id = HOST_SERVICE_ID;
    static constexpr uint16_t major_version = HOST_SERVICE_MAJOR;
};
#endif
