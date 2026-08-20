#ifndef FHE_SERVER_PACKED_WEIGHTS_H
#define FHE_SERVER_PACKED_WEIGHTS_H

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace packed_weights {

struct Entry {
    std::uint64_t offset = 0;
    std::uint64_t count = 0;
};

class Archive {
public:
    explicit Archive(const std::filesystem::path& path);

    bool contains(const std::string& name) const;
    std::vector<double> read(const std::string& name);
    std::size_t entryCount() const noexcept { return entries_.size(); }

private:
    std::filesystem::path path_;
    std::ifstream stream_;
    std::unordered_map<std::string, Entry> entries_;
    std::mutex stream_mutex_;
};

void packDirectory(const std::filesystem::path& input_directory,
                   const std::filesystem::path& output_file);
void verifyDirectory(const std::filesystem::path& input_directory,
                     const std::filesystem::path& archive_file);

}  // namespace packed_weights

#endif
