#include "BatchPolicy.h"

#include <cstdlib>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <string>
#include <utility>

namespace {
void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

void requireThrows(const std::function<void()>& operation, const std::string& message) {
    try {
        operation();
    } catch (const std::runtime_error&) {
        return;
    }
    throw std::runtime_error(message);
}

void setLimit(const char* value) {
    if (value == nullptr) {
        unsetenv("FHE_BATCH_MAX_IMAGES");
    } else {
        setenv("FHE_BATCH_MAX_IMAGES", value, 1);
    }
}
}  // namespace

int main() {
    try {
        setLimit(nullptr);
        require(batch_policy::configuredMaxImages() == 20,
                "default batch limit must be 20");

        for (const auto& test : {std::pair{"1", std::size_t{1}},
                                 std::pair{"20", std::size_t{20}},
                                 std::pair{"190", std::size_t{190}},
                                 std::pair{"1000", std::size_t{1000}}}) {
            setLimit(test.first);
            require(batch_policy::configuredMaxImages() == test.second,
                    "valid configured batch limit was not accepted");
        }

        for (const char* invalid : {"0", "-1", "abc", "20x", "1001", " 20"}) {
            setLimit(invalid);
            requireThrows([] { batch_policy::configuredMaxImages(); },
                          "invalid configured batch limit was accepted");
        }

        batch_policy::enforceImageCount(20, 20);
        requireThrows([] { batch_policy::enforceImageCount(21, 20); },
                      "oversized batch was accepted");

        setLimit(nullptr);
        std::cout << "Batch policy tests passed.\n";
        return 0;
    } catch (const std::exception& error) {
        setLimit(nullptr);
        std::cerr << error.what() << '\n';
        return 1;
    }
}
