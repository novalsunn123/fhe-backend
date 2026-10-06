#include "BufferedKeyInput.h"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>

int main(int argc, char* argv[]) {
    if (argc != 2) return 2;

    const std::filesystem::path filePath = argv[1];
    const std::string expected = "evaluation-key-buffer-test\n" + std::string(200000, 'x');
    {
        std::ofstream output(filePath, std::ios::binary);
        output.write(expected.data(), static_cast<std::streamsize>(expected.size()));
    }

    fhe::BufferedKeyInput input(filePath.string(), {64U * 1024U, 0});
    if (!input.isOpen()) {
        std::cerr << "Cannot open buffered input\n";
        return 1;
    }

    const std::string actual((std::istreambuf_iterator<char>(input.stream())),
                             std::istreambuf_iterator<char>());
    std::filesystem::remove(filePath);
    if (actual != expected) {
        std::cerr << "Buffered input changed file contents\n";
        return 1;
    }
    return 0;
}
