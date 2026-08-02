#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void DuskSaveBridgeSync_Configure(const char* dataDirectory);
void DuskSaveBridgeSync_Pair(const char* code);
void DuskSaveBridgeSync_SyncNow(const char* region);
void DuskSaveBridgeSync_GetStatus(char* buffer, size_t bufferSize);
bool DuskSaveBridgeSync_ConsumeQuestLogReloadRequest();
bool DuskSaveBridgeSync_ConsumeReturnToTitleRequest();

#ifdef __cplusplus
}
#endif
