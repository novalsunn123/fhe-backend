#ifndef FHESERVER_BATCHPOLICY_H
#define FHESERVER_BATCHPOLICY_H

#include <cstddef>

namespace batch_policy {

constexpr std::size_t kDefaultMaxImages = 20;
constexpr std::size_t kHardMaxImages = 1000;

std::size_t configuredMaxImages();
void enforceImageCount(std::size_t image_count, std::size_t max_images);

}  // namespace batch_policy

#endif
