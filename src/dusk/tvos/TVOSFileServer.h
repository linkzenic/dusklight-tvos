#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void DuskTVOSFileServer_StartDiscTransfer(const char* uploadDirectory);
void DuskTVOSFileServer_StartTextureTransfer(const char* uploadDirectory);
void DuskTVOSFileServer_Stop(void);
int DuskTVOSFileServer_IsRunning(void);
void DuskTVOSFileServer_GetStatus(char* buffer, size_t bufferSize);
int DuskTVOSFileServer_TakeUploadedDiscPath(char* buffer, size_t bufferSize);
int DuskTVOSFileServer_TakeUploadedTextureArchive(char* buffer, size_t bufferSize);

#ifdef __cplusplus
}
#endif
