#include "registry.hpp"

#include "dusk/mods/loader/loader.hpp"

namespace dusk::mods::svc {
namespace {

ModResult host_get_service(ModContext*, const char* serviceId, const uint16_t majorVersion,
    const uint16_t minMinorVersion, const void** outService) {
    if (outService == nullptr) {
        return MOD_INVALID_ARGUMENT;
    }
    *outService = nullptr;
    const auto* service = find_service(serviceId, majorVersion, minMinorVersion);
    if (service == nullptr) {
        return MOD_UNAVAILABLE;
    }
    *outService = service->service;
    return MOD_OK;
}

ModResult host_publish_service(
    ModContext* context, const char* serviceId, const uint16_t majorVersion, const void* service) {
    auto* mod = mod_from_context(context);
    if (mod == nullptr || !valid_service_id(serviceId) || service == nullptr) {
        return MOD_INVALID_ARGUMENT;
    }

    return publish_deferred_service(*mod, serviceId, majorVersion, service);
}

void host_fail(ModContext* context, const ModResult code, const char* message) {
    auto* mod = mod_from_context(context);
    if (mod != nullptr) {
        fail_mod(*mod, code, message != nullptr ? message : "mod reported failure");
    }
}

const char* host_mod_id(ModContext* context) {
    const auto* mod = mod_from_context(context);
    return mod != nullptr ? mod->metadata.id.c_str() : "";
}

const char* host_mod_name(ModContext* context) {
    const auto* mod = mod_from_context(context);
    return mod != nullptr ? mod->metadata.name.c_str() : "";
}

const char* host_mod_version(ModContext* context) {
    const auto* mod = mod_from_context(context);
    return mod != nullptr ? mod->metadata.version.c_str() : "";
}

const char* host_mod_dir(ModContext* context) {
    const auto* mod = mod_from_context(context);
    return mod != nullptr ? mod->dir.c_str() : "";
}

constexpr HostService s_hostService{
    .header = SERVICE_HEADER(HostService, HOST_SERVICE_MAJOR, HOST_SERVICE_MINOR),
    .get_service = host_get_service,
    .publish_service = host_publish_service,
    .fail = host_fail,
    .mod_id = host_mod_id,
    .mod_name = host_mod_name,
    .mod_version = host_mod_version,
    .mod_dir = host_mod_dir,
};

}  // namespace

const HostService& host_service() {
    return s_hostService;
}

}  // namespace dusk::mods::svc
