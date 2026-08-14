#include "BatchPolicy.h"

#include <charconv>
#include <cstdlib>
#include <stdexcept>
#include <string>

namespace batch_policy {

std::size_t configuredMaxImages() {
    const char* raw_value = std::getenv("FHE_BATCH_MAX_IMAGES");
    if (raw_value == nullptr || *raw_value == '\0') return kDefaultMaxImages;

    const std::string value(raw_value);
    std::size_t parsed = 0;
    const auto conversion = std::from_chars(value.data(), value.data() + value.size(), parsed);
    if (conversion.ec != std::errc() || conversion.ptr != value.data() + value.size() ||
        parsed == 0 || parsed > kHardMaxImages) {
        throw std::runtime_error(
            "FHE_BATCH_MAX_IMAGES must be an integer between 1 and " +
            std::to_string(kHardMaxImages));
    }
    return parsed;
}

void enforceImageCount(std::size_t image_count, std::size_t max_images) {
    if (image_count > max_images) {
        throw std::runtime_error(
            "Batch contains " + std::to_string(image_count) +
            " images, exceeding the configured limit of " + std::to_string(max_images) +
            ". Split the workload into smaller batches or explicitly set "
            "FHE_BATCH_MAX_IMAGES.");
    }
}

}  // namespace batch_policy
