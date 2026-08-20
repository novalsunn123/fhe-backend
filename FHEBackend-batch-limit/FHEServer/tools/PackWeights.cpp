#include "PackedWeights.h"

#include <filesystem>
#include <iostream>
#include <stdexcept>

int main(int argc, char* argv[]) {
    if (argc != 3) {
        std::cerr << "Usage: FHEWeightPacker <text-weight-directory> <packed-output>\n";
        return 2;
    }
    try {
        packed_weights::packDirectory(argv[1], argv[2]);
        packed_weights::verifyDirectory(argv[1], argv[2]);
        packed_weights::Archive archive(argv[2]);
        std::cout << "Packed and verified " << archive.entryCount() << " weight files into "
                  << std::filesystem::path(argv[2]) << '\n';
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
