#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void DuskTVOSFileServer_StartDiscTransfer(const char* uploadDirectory);
// Starts one local web page for saves, texture packs, and .dusk mods.
void DuskTVOSFileServer_StartUploads(const char* configDirectory);
void DuskTVOSFileServer_StartTextureTransfer(const char* uploadDirectory);
// Starts the restricted save-data upload page for one Dusklight region folder.
void DuskTVOSFileServer_StartSaveTransfer(const char* regionDirectory);
void DuskTVOSFileServer_Stop(void);
int DuskTVOSFileServer_IsRunning(void);
void DuskTVOSFileServer_GetStatus(char* buffer, size_t bufferSize);
int DuskTVOSFileServer_TakeUploadedDiscPath(char* buffer, size_t bufferSize);
int DuskTVOSFileServer_TakeUploadedTextureArchive(char* buffer, size_t bufferSize);

#ifdef __cplusplus
}
#endif
