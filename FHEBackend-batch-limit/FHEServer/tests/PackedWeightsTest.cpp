#include "PackedWeights.h"

#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <vector>

namespace {
bool equal(const std::vector<double>& left, const std::vector<double>& right) {
    if (left.size() != right.size()) return false;
    for (std::size_t index = 0; index < left.size(); ++index) {
        if (left[index] != right[index]) return false;
    }
    return true;
}
}

int main(int argc, char* argv[]) {
    if (argc != 2) return 2;
    const std::filesystem::path root = argv[1];
    std::filesystem::remove_all(root);
    std::filesystem::create_directories(root / "weights");
    {
        std::ofstream first(root / "weights" / "first.bin");
        first << "1.25\n-2.5\n3.125\n";
        std::ofstream second(root / "weights" / "second.bin");
        second << "4.5,5.75\n6.0\n";
    }

    const auto archive_path = root / "packed-weights.bin";
    packed_weights::packDirectory(root / "weights", archive_path);
    packed_weights::verifyDirectory(root / "weights", archive_path);
    packed_weights::Archive archive(archive_path);
    const bool valid = archive.entryCount() == 2 &&
        archive.contains("first.bin") && archive.contains("second.bin") &&
        equal(archive.read("first.bin"), {1.25, -2.5, 3.125}) &&
        equal(archive.read("second.bin"), {4.5, 5.75, 6.0});
    std::filesystem::remove_all(root);
    if (!valid) std::cerr << "Packed weight round-trip differs from text input\n";
    return valid ? 0 : 1;
}
