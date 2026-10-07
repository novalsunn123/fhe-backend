#ifndef FHE_SERVER_PACKED_WEIGHTS_H
#define FHE_SERVER_PACKED_WEIGHTS_H

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <list>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace packed_weights {

struct Entry {
    std::uint64_t offset = 0;
    std::uint64_t count = 0;
};

struct CacheStats {
    std::size_t hits = 0;
    std::size_t misses = 0;
    std::size_t evictions = 0;
    std::size_t bytes = 0;
};

class Archive {
public:
    explicit Archive(const std::filesystem::path& path, std::size_t cache_capacity_bytes = 0);

    bool contains(const std::string& name) const;
    std::vector<double> read(const std::string& name);
    std::size_t entryCount() const noexcept { return entries_.size(); }
    CacheStats cacheStats() const;

private:
    struct CachedEntry {
        std::shared_ptr<const std::vector<double>> values;
        std::size_t bytes = 0;
        std::list<std::string>::iterator recency;
    };

    std::shared_ptr<const std::vector<double>> findCached(const std::string& name);
    void cache(const std::string& name, const std::shared_ptr<const std::vector<double>>& values);

    std::filesystem::path path_;
    std::ifstream stream_;
    std::unordered_map<std::string, Entry> entries_;
    std::mutex stream_mutex_;
    const std::size_t cache_capacity_bytes_;
    mutable std::mutex cache_mutex_;
    std::unordered_map<std::string, CachedEntry> cache_;
    std::list<std::string> recency_;
    mutable CacheStats cache_stats_;
};

void packDirectory(const std::filesystem::path& input_directory,
                   const std::filesystem::path& output_file);
void verifyDirectory(const std::filesystem::path& input_directory,
                     const std::filesystem::path& archive_file);

}  // namespace packed_weights

#endif
