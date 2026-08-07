#ifndef FHESERVER_PROFILER_H
#define FHESERVER_PROFILER_H

#include <chrono>
#include <cstdint>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

struct ProfileEvent {
    std::uint64_t sequence = 0;
    std::string event_type;
    std::string event_name;
    std::string layer;
    std::string block;
    double duration_seconds = 0.0;
    std::string status = "passed";
    std::optional<std::uint32_t> slots;
    std::optional<std::uint32_t> level_before;
    std::optional<std::uint32_t> level_after;
    std::string file;
    std::optional<std::uintmax_t> file_size_bytes;
};

class OperationProfiler {
public:
    static OperationProfiler& instance();

    void configureFromEnvironment();
    bool enabled() const;
    std::uint64_t nextSequence();
    void record(ProfileEvent event);
    void finalize(const std::string& status, const std::string& error_summary = "");

    void setContext(const std::string& layer, const std::string& block);
    std::string currentLayer() const;
    std::string currentBlock() const;

private:
    OperationProfiler() = default;
    void writeMarkdown(const std::string& status, const std::string& error_summary,
                       const std::vector<ProfileEvent>& events) const;
    void writeJson(const std::string& status, const std::string& error_summary,
                   const std::vector<ProfileEvent>& events) const;
    void writeCsv(const std::vector<ProfileEvent>& events) const;

    mutable std::mutex mutex_;
    bool enabled_ = false;
    bool finalized_ = false;
    std::uint64_t next_sequence_ = 1;
    std::string output_directory_;
    std::string commit_;
    std::string branch_;
    std::vector<ProfileEvent> events_;
};

class ProfileContextScope {
public:
    ProfileContextScope(std::string layer, std::string block);
    ~ProfileContextScope();
    void restore();

    ProfileContextScope(const ProfileContextScope&) = delete;
    ProfileContextScope& operator=(const ProfileContextScope&) = delete;

private:
    bool active_ = true;
    std::string previous_layer_;
    std::string previous_block_;
};

class ProfileScope {
public:
    ProfileScope(std::string event_type, std::string event_name,
                 std::string layer = "", std::string block = "");
    ~ProfileScope();

    ProfileScope(const ProfileScope&) = delete;
    ProfileScope& operator=(const ProfileScope&) = delete;

    void setSlots(std::uint32_t slots);
    void setLevelBefore(std::uint32_t level);
    void setLevelAfter(std::uint32_t level);
    void setFile(const std::string& file);
    void fail();
    void finish();

private:
    bool active_ = false;
    int uncaught_exceptions_ = 0;
    std::chrono::steady_clock::time_point started_;
    ProfileEvent event_;
};

#endif
