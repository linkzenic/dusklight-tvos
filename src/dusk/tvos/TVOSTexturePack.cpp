#include "TVOSTexturePack.h"

#include "miniz.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <mutex>
#include <ranges>
#include <string>
#include <thread>

namespace {

constexpr std::uintmax_t kMaximumExpandedBytes =
    16ULL * 1024ULL * 1024ULL * 1024ULL;

std::mutex gStateMutex;
std::string gStatus = "ZIP texture pack upload is ready.";
std::atomic_bool gInstalling{false};
std::atomic_bool gCompleted{false};
std::atomic_bool gSucceeded{false};

void SetStatus(std::string status) {
    std::scoped_lock lock(gStateMutex);
    gStatus = std::move(status);
}

std::string SanitizedPackName(const std::filesystem::path& archive) {
    std::string name = archive.stem().string();
    for (char& ch : name) {
        const bool valid = (ch >= 'a' && ch <= 'z') ||
                           (ch >= 'A' && ch <= 'Z') ||
                           (ch >= '0' && ch <= '9') || ch == '-' || ch == '_';
        if (!valid) {
            ch = '_';
        }
    }
    if (name.empty()) {
        name = "Texture_Pack";
    }
    return name;
}

bool SafeRelativePath(const std::filesystem::path& path) {
    if (path.empty() || path.is_absolute() || path.has_root_path()) {
        return false;
    }
    return std::ranges::none_of(path, [](const auto& component) {
        return component == "..";
    });
}

bool IsTextureFile(const std::filesystem::path& path) {
    std::string extension = path.extension().string();
    std::ranges::transform(extension, extension.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return extension == ".png" || extension == ".dds";
}

bool InstallArchive(
    const std::filesystem::path& archive,
    const std::filesystem::path& textureDirectory,
    std::string& error) {
    mz_zip_archive zip{};
    const auto archiveString = archive.string();
    if (!mz_zip_reader_init_file(&zip, archiveString.c_str(), 0)) {
        error = std::string{"The ZIP file could not be opened: "} +
                mz_zip_get_error_string(mz_zip_get_last_error(&zip));
        return false;
    }

    const auto finishZip = [&] { mz_zip_reader_end(&zip); };
    const auto timestamp =
        std::chrono::steady_clock::now().time_since_epoch().count();
    const auto staging =
        textureDirectory / (".install-" + std::to_string(timestamp));
    const auto destination = textureDirectory / SanitizedPackName(archive);
    std::error_code ec;
    std::filesystem::create_directories(staging, ec);
    if (ec) {
        finishZip();
        error = "Dusklight could not prepare temporary texture-pack storage.";
        return false;
    }

    std::uintmax_t expandedBytes = 0;
    std::size_t textureCount = 0;
    bool valid = true;
    const mz_uint fileCount = mz_zip_reader_get_num_files(&zip);
    for (mz_uint index = 0; index < fileCount; ++index) {
        mz_zip_archive_file_stat stat{};
        if (!mz_zip_reader_file_stat(&zip, index, &stat)) {
            error = "Dusklight could not inspect every entry in the ZIP file.";
            valid = false;
            break;
        }

        const std::filesystem::path relative =
            std::filesystem::u8path(stat.m_filename);
        const unsigned unixType = (stat.m_external_attr >> 16) & 0170000;
        if (!SafeRelativePath(relative) || unixType == 0120000) {
            error = "The ZIP contains an unsafe path or symbolic link.";
            valid = false;
            break;
        }
        if (mz_zip_reader_is_file_a_directory(&zip, index)) {
            continue;
        }
        if (!IsTextureFile(relative)) {
            continue;
        }

        expandedBytes += stat.m_uncomp_size;
        if (expandedBytes > kMaximumExpandedBytes) {
            error = "The expanded texture pack exceeds the 16 GB safety limit.";
            valid = false;
            break;
        }

        const auto output = staging / relative;
        std::filesystem::create_directories(output.parent_path(), ec);
        if (ec) {
            error = "Dusklight could not create the texture-pack folder structure.";
            valid = false;
            break;
        }
        const auto outputString = output.string();
        if (!mz_zip_reader_extract_to_file(
                &zip, index, outputString.c_str(), 0)) {
            error = std::string{"A texture could not be extracted: "} +
                    mz_zip_get_error_string(mz_zip_get_last_error(&zip));
            valid = false;
            break;
        }
        ++textureCount;
    }
    finishZip();

    if (valid && textureCount == 0) {
        error = "The ZIP did not contain any PNG or DDS texture files.";
        valid = false;
    }
    if (!valid) {
        std::filesystem::remove_all(staging, ec);
        return false;
    }

    std::filesystem::create_directories(textureDirectory, ec);
    if (ec) {
        std::filesystem::remove_all(staging, ec);
        error = "Dusklight could not create its texture_replacements folder.";
        return false;
    }

    const auto backup = destination.string() + ".previous";
    std::filesystem::remove_all(backup, ec);
    if (std::filesystem::exists(destination, ec)) {
        std::filesystem::rename(destination, backup, ec);
        if (ec) {
            std::filesystem::remove_all(staging, ec);
            error = "The existing texture pack could not be replaced safely.";
            return false;
        }
    }
    std::filesystem::rename(staging, destination, ec);
    if (ec) {
        std::error_code restoreError;
        if (std::filesystem::exists(backup, restoreError)) {
            std::filesystem::rename(backup, destination, restoreError);
        }
        std::filesystem::remove_all(staging, restoreError);
        error = "The extracted texture pack could not be installed.";
        return false;
    }
    std::filesystem::remove_all(backup, ec);
    SetStatus("Installed " + std::to_string(textureCount) +
              " textures from " + archive.filename().string() + ".");
    return true;
}

}  // namespace

extern "C" void DuskTVOSTexturePack_BeginInstall(
    const char* archivePath, const char* textureDirectory) {
    if (archivePath == nullptr || textureDirectory == nullptr ||
        gInstalling.exchange(true)) {
        return;
    }
    gCompleted.store(false);
    SetStatus("Installing ZIP texture pack…");
    const std::filesystem::path archive = std::filesystem::u8path(archivePath);
    const std::filesystem::path destination =
        std::filesystem::u8path(textureDirectory);
    std::thread([archive, destination] {
        std::string error;
        const bool succeeded = InstallArchive(archive, destination, error);
        std::error_code removeError;
        std::filesystem::remove(archive, removeError);
        if (!succeeded) {
            SetStatus(error);
        }
        gSucceeded.store(succeeded);
        gCompleted.store(true);
        gInstalling.store(false);
    }).detach();
}

extern "C" int DuskTVOSTexturePack_TakeCompleted(int* succeeded) {
    if (!gCompleted.exchange(false)) {
        return 0;
    }
    if (succeeded != nullptr) {
        *succeeded = gSucceeded.load() ? 1 : 0;
    }
    return 1;
}

extern "C" void DuskTVOSTexturePack_GetStatus(
    char* buffer, size_t bufferSize) {
    if (buffer == nullptr || bufferSize == 0) {
        return;
    }
    std::scoped_lock lock(gStateMutex);
    std::strncpy(buffer, gStatus.c_str(), bufferSize - 1);
    buffer[bufferSize - 1] = '\0';
}
