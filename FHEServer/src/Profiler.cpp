#include "Profiler.h"

#include <algorithm>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <map>
#include <sstream>
#include <stdexcept>

namespace {
thread_local std::string profile_layer;
thread_local std::string profile_block;

bool isFalseValue(const std::string& value) {
    return value == "0" || value == "false" || value == "FALSE" ||
           value == "off" || value == "OFF" || value == "no" || value == "NO";
}

std::string environmentValue(const char* name) {
    const char* value = std::getenv(name);
    return value == nullptr ? std::string() : std::string(value);
}

std::string jsonEscape(const std::string& value) {
    std::ostringstream escaped;
    for (const unsigned char c : value) {
        switch (c) {
            case '"': escaped << "\\\""; break;
            case '\\': escaped << "\\\\"; break;
            case '\b': escaped << "\\b"; break;
            case '\f': escaped << "\\f"; break;
            case '\n': escaped << "\\n"; break;
            case '\r': escaped << "\\r"; break;
            case '\t': escaped << "\\t"; break;
            default:
                if (c < 0x20) {
                    escaped << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                            << static_cast<int>(c) << std::dec;
                } else {
                    escaped << c;
                }
        }
    }
    return escaped.str();
}

std::string csvEscape(const std::string& value) {
    if (value.find_first_of(",\"\r\n") == std::string::npos) return value;
    std::string escaped = "\"";
    for (const char c : value) {
        escaped += c == '"' ? "\"\"" : std::string(1, c);
    }
    escaped += '"';
    return escaped;
}

std::optional<double> durationForName(const std::vector<ProfileEvent>& events,
                                      const std::string& name) {
    for (auto it = events.rbegin(); it != events.rend(); ++it) {
        if (it->event_name == name) return it->duration_seconds;
    }
    return std::nullopt;
}

std::optional<double> totalContextAndKeyLoading(const std::vector<ProfileEvent>& events) {
    double total = 0.0;
    bool found = false;
    for (const auto& event : events) {
        if (event.event_type == "key_load" || event.event_name == "crypto_context_deserialization") {
            total += event.duration_seconds;
            found = true;
        }
    }
    return found ? std::optional<double>(total) : std::nullopt;
}

std::string formatDuration(const std::optional<double>& seconds) {
    if (!seconds) return "unavailable";
    std::ostringstream value;
    value << std::fixed << std::setprecision(3) << *seconds << " s";
    return value.str();
}

struct BootstrapSummary {
    std::size_t count = 0;
    double total = 0.0;
    double minimum = 0.0;
    double maximum = 0.0;
    std::string slowest;
};

struct OperationSummary {
    std::size_t count = 0;
    double total = 0.0;
    double maximum = 0.0;
};

const std::vector<std::string>& convolutionOperationTypes() {
    static const std::vector<std::string> types = {
        "weight_file_open", "weight_file_read", "weight_text_parse", "weight_binary_read",
        "plaintext_encode", "rotation_precompute", "fast_rotation",
        "rotation", "eval_mult_plain", "eval_add", "eval_add_many"
    };
    return types;
}

std::map<std::string, OperationSummary> summarizeOperations(
        const std::vector<ProfileEvent>& events) {
    std::map<std::string, OperationSummary> summaries;
    for (const auto& type : convolutionOperationTypes()) summaries[type] = {};
    for (const auto& event : events) {
        auto found = summaries.find(event.event_type);
        if (found == summaries.end()) continue;
        ++found->second.count;
        found->second.total += event.duration_seconds;
        found->second.maximum = std::max(found->second.maximum, event.duration_seconds);
    }
    return summaries;
}

BootstrapSummary summarizeBootstraps(const std::vector<ProfileEvent>& events) {
    BootstrapSummary result;
    for (const auto& event : events) {
        if (event.event_type != "bootstrap") continue;
        if (result.count == 0 || event.duration_seconds < result.minimum) {
            result.minimum = event.duration_seconds;
        }
        if (result.count == 0 || event.duration_seconds > result.maximum) {
            result.maximum = event.duration_seconds;
            result.slowest = event.event_name;
        }
        ++result.count;
        result.total += event.duration_seconds;
    }
    return result;
}

void requireWritable(const std::ofstream& stream, const std::filesystem::path& path) {
    if (!stream) throw std::runtime_error("Cannot write profiler report: " + path.string());
}
}  // namespace

OperationProfiler& OperationProfiler::instance() {
    static OperationProfiler profiler;
    return profiler;
}

void OperationProfiler::configureFromEnvironment() {
    const std::string requested = environmentValue("FHE_PROFILE");
    const std::string explicit_directory = environmentValue("FHE_PROFILE_DIR");
    const std::string ci_directory = environmentValue("CICD_REPORT_DIR");
    const bool explicitly_disabled = !requested.empty() && isFalseValue(requested);
    const bool explicitly_enabled = !requested.empty() && !explicitly_disabled;

    enabled_ = !explicitly_disabled &&
               (explicitly_enabled || !explicit_directory.empty() || !ci_directory.empty());
    if (!enabled_) return;

    output_directory_ = !explicit_directory.empty() ? explicit_directory :
                        (!ci_directory.empty() ? ci_directory : ".");
    commit_ = environmentValue("FHE_BENCHMARK_COMMIT");
    branch_ = environmentValue("FHE_BENCHMARK_BRANCH");

    std::error_code error;
    std::filesystem::create_directories(output_directory_, error);
    if (error) {
        throw std::runtime_error("Cannot create profiler output directory " + output_directory_ +
                                 ": " + error.message());
    }
}

bool OperationProfiler::enabled() const {
    return enabled_;
}

std::uint64_t OperationProfiler::nextSequence() {
    std::lock_guard<std::mutex> lock(mutex_);
    return next_sequence_++;
}

void OperationProfiler::record(ProfileEvent event) {
    if (!enabled_) return;
    std::lock_guard<std::mutex> lock(mutex_);
    events_.push_back(std::move(event));
}

void OperationProfiler::recordDuration(const std::string& event_type,
                                       const std::string& event_name,
                                       double duration_seconds,
                                       const std::string& file,
                                       bool include_file_size) {
    if (!enabled_) return;
    ProfileEvent event;
    event.sequence = nextSequence();
    event.event_type = event_type;
    event.event_name = event_name;
    event.layer = currentLayer();
    event.block = currentBlock();
    event.duration_seconds = duration_seconds;
    event.file = file;
    if (include_file_size && !file.empty()) {
        std::error_code error;
        const auto size = std::filesystem::file_size(file, error);
        if (!error) event.file_size_bytes = size;
    }
    record(std::move(event));
}

void OperationProfiler::setContext(const std::string& layer, const std::string& block) {
    profile_layer = layer;
    profile_block = block;
}

std::string OperationProfiler::currentLayer() const {
    return profile_layer;
}

std::string OperationProfiler::currentBlock() const {
    return profile_block;
}

void OperationProfiler::finalize(const std::string& status, const std::string& error_summary) {
    if (!enabled_) return;
    std::vector<ProfileEvent> events;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (finalized_) return;
        finalized_ = true;
        events = events_;
    }
    std::sort(events.begin(), events.end(), [](const ProfileEvent& left, const ProfileEvent& right) {
        return left.sequence < right.sequence;
    });
    writeMarkdown(status, error_summary, events);
    writeJson(status, error_summary, events);
    writeCsv(events);
}

void OperationProfiler::writeMarkdown(const std::string& status,
                                      const std::string& error_summary,
                                      const std::vector<ProfileEvent>& events) const {
    const std::filesystem::path path =
        std::filesystem::path(output_directory_) / "fhe-operation-profile.md";
    std::ofstream output(path);
    requireWritable(output, path);
    const BootstrapSummary bootstrap = summarizeBootstraps(events);
    const auto operation_summaries = summarizeOperations(events);

    output << "# FHEServer operation profile\n\n"
           << "| Metric | Value |\n|---|---|\n"
           << "| Status | " << status << " |\n"
           << "| Total infer command | " << formatDuration(durationForName(events, "total_infer_command")) << " |\n"
           << "| Context and key loading | " << formatDuration(totalContextAndKeyLoading(events)) << " |\n"
           << "| FHE circuit | " << formatDuration(durationForName(events, "fhe_circuit")) << " |\n"
           << "| Total bootstrap time | " << formatDuration(bootstrap.count ? std::optional<double>(bootstrap.total) : std::nullopt) << " |\n"
           << "| Bootstrap count | " << bootstrap.count << " |\n"
           << "| Average bootstrap | " << formatDuration(bootstrap.count ? std::optional<double>(bootstrap.total / bootstrap.count) : std::nullopt) << " |\n"
           << "| Slowest bootstrap | " << (bootstrap.count ? bootstrap.slowest : "unavailable") << " |\n"
           << "| Layer 1 | " << formatDuration(durationForName(events, "layer_1")) << " |\n"
           << "| Layer 2 | " << formatDuration(durationForName(events, "layer_2")) << " |\n"
           << "| Layer 3 | " << formatDuration(durationForName(events, "layer_3")) << " |\n"
           << "| Final layer | " << formatDuration(durationForName(events, "final_layer")) << " |\n"
           << "| Result serialization | " << formatDuration(durationForName(events, "result_serialization")) << " |\n\n";

    output << "## Runtime context\n\n"
           << "- Commit: " << (commit_.empty() ? "unavailable" : commit_) << "\n"
           << "- Branch: " << (branch_.empty() ? "unavailable" : branch_) << "\n"
           << "- CPU, RAM, and swap: see `metrics.csv` and `benchmark.json`.\n"
           << "- Prediction and decrypted logits: see `summary.md` and `benchmark.json`.\n"
           << "- FHEServer never decrypts the result and never receives the secret key.\n";
    if (!error_summary.empty()) output << "- Error: " << error_summary << "\n";

    output << "\n## Key-loading detail\n\n"
           << "| Event | File | Bytes | Duration | Status |\n|---|---|---:|---:|---|\n";
    for (const auto& event : events) {
        if (event.event_type != "context_load" && event.event_type != "key_load") continue;
        output << "| " << event.event_name << " | "
               << (event.file.empty() ? "—" : event.file) << " | ";
        if (event.file_size_bytes) output << *event.file_size_bytes; else output << "—";
        output << " | " << formatDuration(event.duration_seconds) << " | " << event.status << " |\n";
    }

    output << "\n## Convolution operation breakdown\n\n"
           << "The rows below are non-overlapping operation timers. Weight timers are "
              "recorded per file; cryptographic timers are recorded per call.\n\n"
           << "| Operation | Count | Total | Average | Slowest call |\n"
           << "|---|---:|---:|---:|---:|\n";
    for (const auto& type : convolutionOperationTypes()) {
        const auto& summary = operation_summaries.at(type);
        output << "| " << type << " | " << summary.count << " | "
               << formatDuration(summary.count ? std::optional<double>(summary.total) : std::nullopt)
               << " | "
               << formatDuration(summary.count ? std::optional<double>(summary.total / summary.count) : std::nullopt)
               << " | "
               << formatDuration(summary.count ? std::optional<double>(summary.maximum) : std::nullopt)
               << " |\n";
    }

    output << "\n## Layer and block timings\n\n"
           << "| Type | Event | Layer | Block | Duration | Status |\n|---|---|---|---|---:|---|\n";
    for (const auto& event : events) {
        if (event.event_type != "layer" && event.event_type != "block" &&
            event.event_type != "convolution" && event.event_type != "activation" &&
            event.event_type != "downsample" && event.event_type != "residual") continue;
        output << "| " << event.event_type << " | " << event.event_name << " | "
               << (event.layer.empty() ? "—" : event.layer) << " | "
               << (event.block.empty() ? "—" : event.block) << " | "
               << formatDuration(event.duration_seconds) << " | " << event.status << " |\n";
    }

    output << "\n## Bootstrap detail\n\n"
           << "| # | Event | Layer | Block | Slots | Level before | Level after | Duration | Status |\n"
           << "|---:|---|---|---|---:|---:|---:|---:|---|\n";
    for (const auto& event : events) {
        if (event.event_type != "bootstrap") continue;
        output << "| " << event.sequence << " | " << event.event_name << " | "
               << (event.layer.empty() ? "—" : event.layer) << " | "
               << (event.block.empty() ? "—" : event.block) << " | ";
        if (event.slots) output << *event.slots; else output << "—";
        output << " | ";
        if (event.level_before) output << *event.level_before; else output << "—";
        output << " | ";
        if (event.level_after) output << *event.level_after; else output << "—";
        output << " | " << formatDuration(event.duration_seconds) << " | " << event.status << " |\n";
    }

    std::vector<ProfileEvent> slowest = events;
    std::sort(slowest.begin(), slowest.end(), [](const ProfileEvent& left, const ProfileEvent& right) {
        return left.duration_seconds > right.duration_seconds;
    });
    output << "\n## Top 10 slowest operations\n\n"
           << "| Event | Type | Duration |\n|---|---|---:|\n";
    for (std::size_t i = 0; i < std::min<std::size_t>(10, slowest.size()); ++i) {
        output << "| " << slowest[i].event_name << " | " << slowest[i].event_type
               << " | " << formatDuration(slowest[i].duration_seconds) << " |\n";
    }
    output.flush();
    requireWritable(output, path);
}

void OperationProfiler::writeJson(const std::string& status,
                                  const std::string& error_summary,
                                  const std::vector<ProfileEvent>& events) const {
    const std::filesystem::path path =
        std::filesystem::path(output_directory_) / "fhe-operation-profile.json";
    std::ofstream output(path);
    requireWritable(output, path);
    const BootstrapSummary bootstrap = summarizeBootstraps(events);
    const auto operation_summaries = summarizeOperations(events);
    output << std::fixed << std::setprecision(6)
           << "{\n  \"schema_version\": 2,\n"
           << "  \"status\": \"" << jsonEscape(status) << "\",\n"
           << "  \"error_summary\": ";
    if (error_summary.empty()) output << "null"; else output << "\"" << jsonEscape(error_summary) << "\"";
    output << ",\n  \"commit\": ";
    if (commit_.empty()) output << "null"; else output << "\"" << jsonEscape(commit_) << "\"";
    output << ",\n  \"branch\": ";
    if (branch_.empty()) output << "null"; else output << "\"" << jsonEscape(branch_) << "\"";
    output << ",\n  \"bootstrap_summary\": {\n"
           << "    \"count\": " << bootstrap.count << ",\n"
           << "    \"total_seconds\": " << bootstrap.total << ",\n"
           << "    \"average_seconds\": ";
    if (bootstrap.count) output << bootstrap.total / bootstrap.count; else output << "null";
    output << ",\n    \"minimum_seconds\": ";
    if (bootstrap.count) output << bootstrap.minimum; else output << "null";
    output << ",\n    \"maximum_seconds\": ";
    if (bootstrap.count) output << bootstrap.maximum; else output << "null";
    output << ",\n    \"slowest_event\": ";
    if (bootstrap.count) output << "\"" << jsonEscape(bootstrap.slowest) << "\""; else output << "null";
    output << "\n  },\n  \"duration_summary\": {\n"
           << "    \"total_infer_command_seconds\": ";
    const auto total_infer = durationForName(events, "total_infer_command");
    if (total_infer) output << *total_infer; else output << "null";
    output << ",\n    \"context_and_key_loading_seconds\": ";
    const auto key_loading = totalContextAndKeyLoading(events);
    if (key_loading) output << *key_loading; else output << "null";
    output << ",\n    \"fhe_circuit_seconds\": ";
    const auto circuit = durationForName(events, "fhe_circuit");
    if (circuit) output << *circuit; else output << "null";
    for (const char* name : {"initial_layer", "layer_1", "layer_2", "layer_3", "final_layer", "result_serialization"}) {
        output << ",\n    \"" << name << "_seconds\": ";
        const auto duration = durationForName(events, name);
        if (duration) output << *duration; else output << "null";
    }
    output << "\n  },\n  \"convolution_operation_summary\": {";
    bool first_operation = true;
    for (const auto& type : convolutionOperationTypes()) {
        const auto& summary = operation_summaries.at(type);
        output << (first_operation ? "\n" : ",\n")
               << "    \"" << jsonEscape(type) << "\": {\"count\": " << summary.count
               << ", \"total_seconds\": " << summary.total
               << ", \"average_seconds\": ";
        if (summary.count) output << summary.total / summary.count; else output << "null";
        output << ", \"maximum_seconds\": ";
        if (summary.count) output << summary.maximum; else output << "null";
        output << "}";
        first_operation = false;
    }
    if (!first_operation) output << '\n';
    output << "  },\n  \"block_summary\": {";
    bool first_block = true;
    for (const auto& event : events) {
        if (event.event_type != "block") continue;
        output << (first_block ? "\n" : ",\n")
               << "    \"" << jsonEscape(event.event_name) << "_seconds\": "
               << event.duration_seconds;
        first_block = false;
    }
    if (!first_block) output << '\n';
    output << "  },\n  \"events\": [\n";
    for (std::size_t i = 0; i < events.size(); ++i) {
        const auto& event = events[i];
        output << "    {\"sequence\": " << event.sequence
               << ", \"event_type\": \"" << jsonEscape(event.event_type)
               << "\", \"event_name\": \"" << jsonEscape(event.event_name)
               << "\", \"layer\": ";
        if (event.layer.empty()) output << "null"; else output << "\"" << jsonEscape(event.layer) << "\"";
        output << ", \"block\": ";
        if (event.block.empty()) output << "null"; else output << "\"" << jsonEscape(event.block) << "\"";
        output << ", \"duration_seconds\": " << event.duration_seconds
               << ", \"status\": \"" << jsonEscape(event.status) << "\", \"slots\": ";
        if (event.slots) output << *event.slots; else output << "null";
        output << ", \"level_before\": ";
        if (event.level_before) output << *event.level_before; else output << "null";
        output << ", \"level_after\": ";
        if (event.level_after) output << *event.level_after; else output << "null";
        output << ", \"file\": ";
        if (event.file.empty()) output << "null"; else output << "\"" << jsonEscape(event.file) << "\"";
        output << ", \"file_size_bytes\": ";
        if (event.file_size_bytes) output << *event.file_size_bytes; else output << "null";
        output << "}" << (i + 1 == events.size() ? "\n" : ",\n");
    }
    output << "  ]\n}\n";
    output.flush();
    requireWritable(output, path);
}

void OperationProfiler::writeCsv(const std::vector<ProfileEvent>& events) const {
    const std::filesystem::path path =
        std::filesystem::path(output_directory_) / "fhe-operation-events.csv";
    std::ofstream output(path);
    requireWritable(output, path);
    output << "sequence,event_type,event_name,layer,block,duration_seconds,status,slots,level_before,level_after,file,file_size_bytes\n";
    output << std::fixed << std::setprecision(6);
    for (const auto& event : events) {
        output << event.sequence << ',' << csvEscape(event.event_type) << ','
               << csvEscape(event.event_name) << ',' << csvEscape(event.layer) << ','
               << csvEscape(event.block) << ',' << event.duration_seconds << ','
               << csvEscape(event.status) << ',';
        if (event.slots) output << *event.slots;
        output << ',';
        if (event.level_before) output << *event.level_before;
        output << ',';
        if (event.level_after) output << *event.level_after;
        output << ',' << csvEscape(event.file) << ',';
        if (event.file_size_bytes) output << *event.file_size_bytes;
        output << '\n';
    }
    output.flush();
    requireWritable(output, path);
}

ProfileContextScope::ProfileContextScope(std::string layer, std::string block)
    : previous_layer_(OperationProfiler::instance().currentLayer()),
      previous_block_(OperationProfiler::instance().currentBlock()) {
    OperationProfiler::instance().setContext(layer, block);
}

ProfileContextScope::~ProfileContextScope() {
    restore();
}

void ProfileContextScope::restore() {
    if (!active_) return;
    active_ = false;
    OperationProfiler::instance().setContext(previous_layer_, previous_block_);
}

ProfileScope::ProfileScope(std::string event_type, std::string event_name,
                           std::string layer, std::string block) {
    OperationProfiler& profiler = OperationProfiler::instance();
    if (!profiler.enabled()) return;
    active_ = true;
    uncaught_exceptions_ = std::uncaught_exceptions();
    started_ = std::chrono::steady_clock::now();
    event_.sequence = profiler.nextSequence();
    event_.event_type = std::move(event_type);
    event_.event_name = std::move(event_name);
    event_.layer = layer.empty() ? profiler.currentLayer() : std::move(layer);
    event_.block = block.empty() ? profiler.currentBlock() : std::move(block);
}

ProfileScope::~ProfileScope() {
    finish();
}

void ProfileScope::finish() {
    if (!active_) return;
    active_ = false;
    const auto ended = std::chrono::steady_clock::now();
    event_.duration_seconds = std::chrono::duration<double>(ended - started_).count();
    if (std::uncaught_exceptions() > uncaught_exceptions_) event_.status = "failed";
    OperationProfiler::instance().record(std::move(event_));
}

void ProfileScope::setSlots(std::uint32_t slots) { if (active_) event_.slots = slots; }
void ProfileScope::setLevelBefore(std::uint32_t level) { if (active_) event_.level_before = level; }
void ProfileScope::setLevelAfter(std::uint32_t level) { if (active_) event_.level_after = level; }

void ProfileScope::setFile(const std::string& file) {
    if (!active_) return;
    event_.file = file;
    std::error_code error;
    const auto size = std::filesystem::file_size(file, error);
    if (!error) event_.file_size_bytes = size;
}

void ProfileScope::fail() { if (active_) event_.status = "failed"; }
