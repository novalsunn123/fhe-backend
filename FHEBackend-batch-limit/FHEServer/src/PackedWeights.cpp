#include "PackedWeights.h"

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <system_error>

namespace packed_weights {
namespace {

constexpr std::array<char, 8> kMagic{{'F', 'H', 'E', 'W', 'G', 'T', '0', '1'}};
constexpr std::uint32_t kVersion = 1;

template <typename T>
void writeValue(std::ofstream& output, const T& value) {
    output.write(reinterpret_cast<const char*>(&value), sizeof(value));
    if (!output) throw std::runtime_error("Cannot write packed weight archive");
}

template <typename T>
T readValue(std::ifstream& input) {
    T value{};
    input.read(reinterpret_cast<char*>(&value), sizeof(value));
    if (!input) throw std::runtime_error("Truncated packed weight archive");
    return value;
}

std::vector<double> parseTextWeights(const std::filesystem::path& path) {
    std::ifstream input(path);
    if (!input) throw std::runtime_error("Cannot open weight file: " + path.string());

    std::vector<double> values;
    std::string line;
    while (std::getline(input, line)) {
        const char* cursor = line.c_str();
        while (*cursor != '\0') {
            while (*cursor == ',' || *cursor == ' ' || *cursor == '\t' || *cursor == '\r') ++cursor;
            if (*cursor == '\0') break;
            char* end = nullptr;
            errno = 0;
            const double value = std::strtod(cursor, &end);
            if (end == cursor || errno == ERANGE) {
                throw std::runtime_error("Invalid numeric value in " + path.string());
            }
            values.push_back(value);
            cursor = end;
        }
    }
    if (!input.eof()) throw std::runtime_error("Cannot read weight file: " + path.string());
    return values;
}

std::uint64_t streamOffset(std::ifstream& input) {
    const auto position = input.tellg();
    if (position < 0) throw std::runtime_error("Invalid packed archive offset");
    return static_cast<std::uint64_t>(position);
}

}  // namespace

Archive::Archive(const std::filesystem::path& path) : path_(path), stream_(path, std::ios::binary) {
    if (!stream_) throw std::runtime_error("Cannot open packed weight archive: " + path.string());

    std::array<char, kMagic.size()> magic{};
    stream_.read(magic.data(), static_cast<std::streamsize>(magic.size()));
    if (!stream_ || magic != kMagic) {
        throw std::runtime_error("Invalid packed weight archive magic: " + path.string());
    }
    const auto version = readValue<std::uint32_t>(stream_);
    if (version != kVersion) {
        throw std::runtime_error("Unsupported packed weight archive version: " + std::to_string(version));
    }
    const auto entry_count = readValue<std::uint32_t>(stream_);
    const auto file_size = std::filesystem::file_size(path_);
    for (std::uint32_t index = 0; index < entry_count; ++index) {
        const auto name_size = readValue<std::uint32_t>(stream_);
        if (name_size == 0 || name_size > 4096) {
            throw std::runtime_error("Invalid packed weight entry name length");
        }
        std::string name(name_size, '\0');
        stream_.read(name.data(), static_cast<std::streamsize>(name.size()));
        if (!stream_) throw std::runtime_error("Truncated packed weight entry name");
        const auto value_count = readValue<std::uint64_t>(stream_);
        if (value_count > std::numeric_limits<std::uint64_t>::max() / sizeof(double)) {
            throw std::runtime_error("Packed weight entry is too large: " + name);
        }
        const auto data_offset = streamOffset(stream_);
        const auto data_bytes = value_count * sizeof(double);
        if (data_offset > file_size || data_bytes > file_size - data_offset) {
            throw std::runtime_error("Packed weight entry exceeds archive size: " + name);
        }
        if (!entries_.emplace(name, Entry{data_offset, value_count}).second) {
            throw std::runtime_error("Duplicate packed weight entry: " + name);
        }
        stream_.seekg(static_cast<std::streamoff>(data_bytes), std::ios::cur);
        if (!stream_) throw std::runtime_error("Cannot seek packed weight archive");
    }
}

bool Archive::contains(const std::string& name) const {
    return entries_.find(name) != entries_.end();
}

std::vector<double> Archive::read(const std::string& name) {
    const auto found = entries_.find(name);
    if (found == entries_.end()) throw std::runtime_error("Packed weight is missing: " + name);
    if (found->second.count > std::numeric_limits<std::size_t>::max()) {
        throw std::runtime_error("Packed weight does not fit in memory: " + name);
    }

    std::vector<double> values(static_cast<std::size_t>(found->second.count));
    std::lock_guard<std::mutex> lock(stream_mutex_);
    stream_.clear();
    stream_.seekg(static_cast<std::streamoff>(found->second.offset));
    stream_.read(reinterpret_cast<char*>(values.data()),
                 static_cast<std::streamsize>(values.size() * sizeof(double)));
    if (!stream_) throw std::runtime_error("Cannot read packed weight: " + name);
    return values;
}

void packDirectory(const std::filesystem::path& input_directory,
                   const std::filesystem::path& output_file) {
    if (!std::filesystem::is_directory(input_directory)) {
        throw std::runtime_error("Weight directory does not exist: " + input_directory.string());
    }

    std::vector<std::filesystem::path> files;
    for (const auto& item : std::filesystem::directory_iterator(input_directory)) {
        if (item.is_regular_file() && item.path().extension() == ".bin") files.push_back(item.path());
    }
    std::sort(files.begin(), files.end(), [](const auto& left, const auto& right) {
        return left.filename().string() < right.filename().string();
    });
    if (files.empty()) throw std::runtime_error("No text weight files found in: " + input_directory.string());
    if (files.size() > std::numeric_limits<std::uint32_t>::max()) {
        throw std::runtime_error("Too many weight files to pack");
    }

    std::filesystem::create_directories(output_file.parent_path());
    const auto temporary = output_file.string() + ".tmp";
    std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
    if (!output) throw std::runtime_error("Cannot create packed weight archive: " + temporary);
    output.write(kMagic.data(), static_cast<std::streamsize>(kMagic.size()));
    writeValue(output, kVersion);
    writeValue(output, static_cast<std::uint32_t>(files.size()));

    try {
        for (const auto& path : files) {
            const std::string name = path.filename().string();
            const auto values = parseTextWeights(path);
            writeValue(output, static_cast<std::uint32_t>(name.size()));
            output.write(name.data(), static_cast<std::streamsize>(name.size()));
            writeValue(output, static_cast<std::uint64_t>(values.size()));
            output.write(reinterpret_cast<const char*>(values.data()),
                         static_cast<std::streamsize>(values.size() * sizeof(double)));
            if (!output) throw std::runtime_error("Cannot write packed weight entry: " + name);
        }
        output.flush();
        if (!output) throw std::runtime_error("Cannot flush packed weight archive");
        output.close();
        std::filesystem::rename(temporary, output_file);
    } catch (...) {
        output.close();
        std::error_code ignored;
        std::filesystem::remove(temporary, ignored);
        throw;
    }
}

void verifyDirectory(const std::filesystem::path& input_directory,
                     const std::filesystem::path& archive_file) {
    Archive archive(archive_file);
    std::size_t file_count = 0;
    for (const auto& item : std::filesystem::directory_iterator(input_directory)) {
        if (!item.is_regular_file() || item.path().extension() != ".bin") continue;
        ++file_count;
        const auto expected = parseTextWeights(item.path());
        const auto actual = archive.read(item.path().filename().string());
        if (expected != actual) {
            throw std::runtime_error("Packed weight verification failed: " + item.path().string());
        }
    }
    if (file_count != archive.entryCount()) {
        throw std::runtime_error("Packed weight archive contains an unexpected number of entries");
    }
}

}  // namespace packed_weights
