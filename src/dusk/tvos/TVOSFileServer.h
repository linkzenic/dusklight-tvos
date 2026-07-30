#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void DuskTVOSFileServer_Start(const char* uploadDirectory);
void DuskTVOSFileServer_Stop(void);
int DuskTVOSFileServer_IsRunning(void);
void DuskTVOSFileServer_GetStatus(char* buffer, size_t bufferSize);
int DuskTVOSFileServer_TakeUploadedPath(char* buffer, size_t bufferSize);

#ifdef __cplusplus
}
#endif
