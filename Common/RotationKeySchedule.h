#ifndef FHE_ROTATION_KEY_SCHEDULE_H
#define FHE_ROTATION_KEY_SCHEDULE_H

#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace fhe_rotation_keys {

struct KeySet {
    const char* filename;
    std::uint32_t bootstrap_slots;
    std::vector<std::int32_t> application_rotations;
};

inline const std::vector<KeySet>& schedule() {
    static const std::vector<KeySet> value = {
        {"rotations-layer1.bin", 16384, {1, -1, 32, -32, -1024, 1024}},
        {"rotations-layer2-downsample.bin", 0, {1, 4, 8, 48, -768, 24576, -8192}},
        {"rotations-layer2.bin", 8192, {1, -1, 16, -16, -256}},
        {"rotations-layer3-downsample.bin", 0, {1, 4, 24, -192, 12288, -4096}},
        {"rotations-layer3.bin", 4096, {1, -1, 8, -8, -64}},
        {"rotations-finallayer.bin", 0,
         {1, 2, 4, 8, 16, 32, -15, 64, 128, 256, 512, 1024, 2048}},
    };
    return value;
}

inline const KeySet& find(const std::string& filename) {
    for (const auto& key_set : schedule()) {
        if (filename == key_set.filename) return key_set;
    }
    throw std::invalid_argument("Unknown rotation key set: " + filename);
}

}  // namespace fhe_rotation_keys

#endif
