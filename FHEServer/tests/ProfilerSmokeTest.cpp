#include "Profiler.h"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

namespace {
std::string readFile(const std::filesystem::path& path) {
    std::ifstream input(path);
    std::ostringstream contents;
    contents << input.rdbuf();
    return contents.str();
}

bool contains(const std::string& text, const std::string& expected) {
    if (text.find(expected) != std::string::npos) return true;
    std::cerr << "Missing profiler output fragment: " << expected << '\n';
    return false;
}
}  // namespace

int main(int argc, char* argv[]) {
    if (argc < 2 || argc > 3) {
        std::cerr << "Usage: ProfilerSmokeTest <output-directory> [disabled]\n";
        return 2;
    }

    const std::filesystem::path output_directory = argv[1];
    std::filesystem::remove_all(output_directory);
    const bool disabled = argc == 3 && std::string(argv[2]) == "disabled";
    if (disabled) {
        unsetenv("FHE_PROFILE_DIR");
        if (setenv("FHE_PROFILE", "0", 1) != 0) return 2;
        OperationProfiler& profiler = OperationProfiler::instance();
        profiler.configureFromEnvironment();
        profiler.recordDuration("rotation", "must_not_be_recorded", 1.0);
        profiler.finalize("passed");
        return std::filesystem::exists(output_directory) ? 1 : 0;
    }

    if (setenv("FHE_PROFILE", "1", 1) != 0 ||
        setenv("FHE_PROFILE_DIR", output_directory.c_str(), 1) != 0) {
        std::cerr << "Cannot configure profiler test environment\n";
        return 2;
    }

    OperationProfiler& profiler = OperationProfiler::instance();
    profiler.configureFromEnvironment();
    profiler.setContext("Layer test", "Block test");
    profiler.recordDuration("weight_file_read", "read_weight_file", 0.010);
    profiler.recordDuration("weight_text_parse", "parse_weight_text", 0.020);
    profiler.recordDuration("plaintext_encode", "encode_vector_plaintext", 0.030);
    profiler.recordDuration("rotation_precompute", "rotation_precompute", 0.040);
    profiler.recordDuration("fast_rotation", "fast_rotation", 0.050);
    profiler.setRotationKeySet("rotations-layer1.bin");
    {
        ProfileScope rotation("rotation", "rotation");
        rotation.setRotationIndex(1);
    }
    profiler.recordDuration("eval_mult_plain", "eval_mult_plain", 0.070);
    profiler.recordDuration("eval_add", "eval_add", 0.080);
    profiler.recordDuration("eval_add_many", "eval_add_many", 0.090);
    profiler.finalize("passed");

    const std::string json = readFile(output_directory / "fhe-operation-profile.json");
    const std::string markdown = readFile(output_directory / "fhe-operation-profile.md");
    const std::string csv = readFile(output_directory / "fhe-operation-events.csv");

    const bool valid =
        contains(json, "\"schema_version\": 3") &&
        contains(json, "\"convolution_operation_summary\"") &&
        contains(json, "\"rotation_usage_summary\"") &&
        contains(json, "\"rotation_index\": 1") &&
        contains(json, "\"fast_rotation\": {\"count\": 1") &&
        contains(markdown, "## Convolution operation breakdown") &&
        contains(markdown, "## Application rotation-key audit") &&
        contains(markdown, "| rotations-layer1.bin | rotation | 1 | 1 |") &&
        contains(markdown, "| eval_mult_plain | 1 |") &&
        contains(csv, "rotation_index,rotation_key_set") &&
        contains(csv, "weight_text_parse,parse_weight_text,Layer test,Block test");
    return valid ? 0 : 1;
}
