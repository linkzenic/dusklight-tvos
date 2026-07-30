#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void DuskICloudSaveSync_Configure(const char* dataDirectory);
void DuskICloudSaveSync_PrepareSaves(void);
void DuskICloudSaveSync_StartMonitoring(void);
void DuskICloudSaveSync_StopMonitoring(void);
void DuskICloudSaveSync_SyncNow(void);
void DuskICloudSaveSync_GetStatus(char* buffer, size_t bufferSize);

#ifdef __cplusplus
}
#endif
