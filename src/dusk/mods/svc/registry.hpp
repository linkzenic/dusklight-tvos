#pragma once

#include "dusk/mod_loader.hpp"
#include "mods/svc/host.h"
#include "mods/svc/log.h"

#include <cstdint>
#include <string>

namespace dusk::mods::svc {

struct ServiceRecord {
    std::string id;
    uint16_t majorVersion = 0;
    uint16_t minorVersion = 0;
    const void* service = nullptr;
    LoadedMod* provider = nullptr;
    bool deferred = false;
};

bool valid_service_id(const char* serviceId);
ModResult register_service(const char* serviceId, uint16_t majorVersion, uint16_t minorVersion,
    const void* service, LoadedMod* provider, bool deferred);
ModResult publish_deferred_service(
    LoadedMod& provider, const char* serviceId, uint16_t majorVersion, const void* service);
void remove_services_for_provider(const LoadedMod& provider);
const ServiceRecord* find_service(
    const char* serviceId, uint16_t majorVersion, uint16_t minMinorVersion);
// Unlike find_service, also returns deferred records that have not been published yet.
const ServiceRecord* find_service_record(const char* serviceId, uint16_t majorVersion);
void clear_services();

const HostService& host_service();
const LogService& log_service();

}  // namespace dusk::mods::svc
