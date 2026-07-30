#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void DuskTVOSTexturePack_BeginInstall(
    const char* archivePath, const char* textureDirectory);
int DuskTVOSTexturePack_TakeCompleted(int* succeeded);
void DuskTVOSTexturePack_GetStatus(char* buffer, size_t bufferSize);

#ifdef __cplusplus
}
#endif
