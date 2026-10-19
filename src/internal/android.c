#define _BSD_SOURCE 1
#include <android/asset_manager.h>
#include <android/configuration.h>
#include <android/native_activity.h>
#include <stdio.h>
#include <string.h>
#include "sokol_app.h"

// 返回安卓界面密度，将界面尺寸转换为原生窗口像素。
float zhu_android_density(void) {
    ANativeActivity* activity =
        (ANativeActivity*)sapp_android_get_native_activity();
    AConfiguration* config = AConfiguration_new();
    AConfiguration_fromAssetManager(config, activity->assetManager);
    const int density = AConfiguration_getDensity(config);
    AConfiguration_delete(config);
    return (float)density / 160.0f;
}

static int asset_read(void* asset, char* buffer, int size) {
    return AAsset_read((AAsset*)asset, buffer, size);
}

static fpos_t asset_seek(void* asset, fpos_t offset, int origin) {
    return AAsset_seek((AAsset*)asset, offset, origin);
}

static int asset_close(void* asset) {
    AAsset_close((AAsset*)asset);
    return 0;
}

// assets/ 路径读取 APK，其余路径使用普通文件系统。
FILE* zhu_android_fopen(const char* path) {
    if (strncmp(path, "assets/", 7) != 0) return fopen(path, "rb");
    ANativeActivity* activity =
        (ANativeActivity*)sapp_android_get_native_activity();
    AAsset* asset = AAssetManager_open(activity->assetManager,
        path + 7, AASSET_MODE_RANDOM);
    if (!asset) return NULL;
    FILE* stream = funopen(asset, asset_read, NULL,
        asset_seek, asset_close);
    if (!stream) AAsset_close(asset);
    return stream;
}
