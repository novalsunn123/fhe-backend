#pragma once

// A small, bounded wrapper around a block-buffered stream for large serialized
// evaluation-key files. The OpenFHE deserializer remains the owner of the
// serialization format; this class only controls how bytes reach it.

#include <charconv>
#include <cstdlib>
#include <fstream>
#include <istream>
#include <memory>
#include <string>
#include <vector>

#if defined(__linux__)
#include <ext/stdio_filebuf.h>
#include <fcntl.h>
#include <unistd.h>
#endif

namespace fhe {

constexpr std::size_t kDefaultKeyInputBufferBytes = 8U * 1024U * 1024U;
constexpr std::size_t kDefaultKeyReadaheadBytes = 32U * 1024U * 1024U;
constexpr std::size_t kMinKeyInputBufferBytes = 64U * 1024U;
constexpr std::size_t kMaxKeyInputBufferBytes = 64U * 1024U * 1024U;
constexpr std::size_t kMaxKeyReadaheadBytes = 64U * 1024U * 1024U;

struct KeyInputConfig {
    std::size_t bufferBytes = kDefaultKeyInputBufferBytes;
    std::size_t readaheadBytes = kDefaultKeyReadaheadBytes;
};

inline std::size_t environmentBytes(const char* name,
                                    std::size_t fallback,
                                    std::size_t minimum,
                                    std::size_t maximum,
                                    bool allowZero) {
#if defined(_MSC_VER)
#pragma warning(push)
#pragma warning(disable : 4996)
#endif
    const char* value = std::getenv(name);
#if defined(_MSC_VER)
#pragma warning(pop)
#endif
    if (value == nullptr || *value == '\0') return fallback;

    unsigned long long parsed = 0;
    const char* end = value;
    while (*end != '\0') ++end;
    const auto result = std::from_chars(value, end, parsed);
    if (result.ec != std::errc{} || result.ptr != end ||
        parsed > static_cast<unsigned long long>(maximum) ||
        (!allowZero && parsed == 0) ||
        (parsed != 0 && parsed < static_cast<unsigned long long>(minimum))) {
        return fallback;
    }
    return static_cast<std::size_t>(parsed);
}

inline KeyInputConfig keyInputConfigFromEnvironment() {
    return {
        environmentBytes("FHE_KEY_IO_BUFFER_BYTES", kDefaultKeyInputBufferBytes,
                         kMinKeyInputBufferBytes, kMaxKeyInputBufferBytes, false),
        environmentBytes("FHE_KEY_READAHEAD_BYTES", kDefaultKeyReadaheadBytes,
                         0, kMaxKeyReadaheadBytes, true),
    };
}

class BufferedKeyInput {
public:
    explicit BufferedKeyInput(const std::string& path,
                              KeyInputConfig config = keyInputConfigFromEnvironment())
        : stream_(nullptr) {
        open(path, config);
    }

    BufferedKeyInput(const BufferedKeyInput&) = delete;
    BufferedKeyInput& operator=(const BufferedKeyInput&) = delete;

    bool isOpen() const {
#if defined(__linux__)
        return fileBuffer_ != nullptr && fileBuffer_->is_open();
#else
        return fileBuffer_.is_open();
#endif
    }

    std::istream& stream() { return stream_; }

private:
#if defined(__linux__)
    void open(const std::string& path, KeyInputConfig config) {
        const int descriptor = ::open(path.c_str(), O_RDONLY);
        if (descriptor == -1) return;

        (void)::posix_fadvise(descriptor, 0, 0, POSIX_FADV_SEQUENTIAL);
        if (config.readaheadBytes > 0) {
            (void)::posix_fadvise(descriptor, 0,
                                  static_cast<off_t>(config.readaheadBytes),
                                  POSIX_FADV_WILLNEED);
        }
        try {
            fileBuffer_ = std::make_unique<__gnu_cxx::stdio_filebuf<char>>(
                descriptor, std::ios::in | std::ios::binary, config.bufferBytes);
        } catch (...) {
            (void)::close(descriptor);
            throw;
        }
        stream_.rdbuf(fileBuffer_.get());
    }
#else
    void open(const std::string& path, KeyInputConfig config) {
        buffer_.resize(config.bufferBytes);
        fileBuffer_.pubsetbuf(buffer_.data(), static_cast<std::streamsize>(buffer_.size()));
        fileBuffer_.open(path, std::ios::in | std::ios::binary);
        stream_.rdbuf(&fileBuffer_);
    }
#endif

#if defined(__linux__)
    std::unique_ptr<__gnu_cxx::stdio_filebuf<char>> fileBuffer_;
#else
    std::vector<char> buffer_;
    std::filebuf fileBuffer_;
#endif
    std::istream stream_;
};

}  // namespace fhe
