#include <algorithm>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#include "FHEController.h"
#include "RotationKeySchedule.h"

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

namespace fs = std::filesystem;

namespace {

void usage() {
    std::cout
        << "Usage:\n"
        << "  FHEClient generate_keys <experiment>\n"
        << "  FHEClient regenerate_server_keys <experiment>\n"
        << "  FHEClient encrypt <experiment> <image> <ciphertext-output>\n"
        << "  FHEClient decrypt <experiment> <ciphertext-result>\n";
}

std::string key_folder(const std::string& experiment) {
    return "keys_exp" + experiment;
}

std::vector<double> read_image(const std::string& filename) {
    int width = 0, height = 0, channels = 0;
    unsigned char* data = stbi_load(filename.c_str(), &width, &height, &channels, 0);
    if (!data) throw std::runtime_error("Cannot load image: " + filename);
    if (width != 32 || height != 32 || channels != 3) {
        stbi_image_free(data);
        throw std::runtime_error("Input must be a 32x32 RGB image: " + filename);
    }

    std::vector<double> result;
    result.reserve(32 * 32 * 3);
    for (int channel = 0; channel < 3; ++channel) {
        for (int pixel = 0; pixel < width * height; ++pixel) {
            result.push_back((static_cast<double>(data[3 * pixel + channel]) / 255.0 - 0.5) / 0.5);
        }
    }
    stbi_image_free(data);
    return result;
}

void link_or_copy(const fs::path& source, const fs::path& destination) {
    if (fs::exists(destination) && fs::equivalent(source, destination)) return;
    if (fs::exists(destination)) fs::remove(destination);
    std::error_code error;
    fs::create_hard_link(source, destination, error);
    if (error) fs::copy_file(source, destination, fs::copy_options::overwrite_existing);
}

void export_server_keys(const std::string& client_folder, const std::string& server_folder) {
    fs::create_directories("../" + server_folder);
    const std::vector<std::string> files = {
        "crypto-context.txt", "public-key.txt", "mult-keys.txt",
        "level_budget.txt", "relu_degree.txt",
        "rot_rotations-layer1.bin", "rot_rotations-layer2-downsample.bin",
        "rot_rotations-layer2.bin", "rot_rotations-layer3-downsample.bin",
        "rot_rotations-layer3.bin", "rot_rotations-finallayer.bin"
    };
    for (const auto& file : files) {
        link_or_copy("../" + client_folder + "/" + file, "../" + server_folder + "/" + file);
    }
    fs::remove("../" + server_folder + "/secret-key.txt");
}

void generate_keys(const std::string& experiment) {
    const int id = std::stoi(experiment);
    if (id < 1 || id > 4) throw std::runtime_error("Experiment must be 1, 2, 3, or 4");

    const std::string folder = key_folder(experiment);
    if (fs::exists("../" + folder) && !fs::is_empty("../" + folder)) {
        throw std::runtime_error("Key folder is not empty: ../" + folder);
    }
    fs::create_directories("../" + folder);

    FHEController controller;
    controller.parameters_folder = folder;
    if (id == 1) controller.generate_context(16, 52, 48, 2, 3, 3, 59, true);
    if (id == 2) controller.generate_context(16, 50, 46, 3, 4, 4, 200, true);
    if (id == 3) controller.generate_context(16, 50, 46, 3, 5, 4, 119, true);
    if (id == 4) controller.generate_context(16, 48, 44, 2, 4, 4, 59, true);

    const auto& layer1_keys = fhe_rotation_keys::find("rotations-layer1.bin");
    controller.generate_bootstrapping_and_rotation_keys(
        layer1_keys.application_rotations, layer1_keys.bootstrap_slots, true,
        layer1_keys.filename);
    controller.clear_context(16384); controller.load_context(false);
    const auto& layer2_downsample_keys =
        fhe_rotation_keys::find("rotations-layer2-downsample.bin");
    controller.generate_rotation_keys(layer2_downsample_keys.application_rotations, true,
                                      layer2_downsample_keys.filename);
    controller.clear_context(0); controller.load_context(false);
    const auto& layer2_keys = fhe_rotation_keys::find("rotations-layer2.bin");
    controller.generate_bootstrapping_and_rotation_keys(
        layer2_keys.application_rotations, layer2_keys.bootstrap_slots, true,
        layer2_keys.filename);
    controller.clear_context(8192); controller.load_context(false);
    const auto& layer3_downsample_keys =
        fhe_rotation_keys::find("rotations-layer3-downsample.bin");
    controller.generate_rotation_keys(layer3_downsample_keys.application_rotations, true,
                                      layer3_downsample_keys.filename);
    controller.clear_context(0); controller.load_context(false);
    const auto& layer3_keys = fhe_rotation_keys::find("rotations-layer3.bin");
    controller.generate_bootstrapping_and_rotation_keys(
        layer3_keys.application_rotations, layer3_keys.bootstrap_slots, true,
        layer3_keys.filename);
    controller.clear_context(4096); controller.load_context(false);
    const auto& final_keys = fhe_rotation_keys::find("rotations-finallayer.bin");
    controller.generate_rotation_keys(final_keys.application_rotations, true,
                                      final_keys.filename);

    const std::string server_folder = "server_keys_exp" + experiment;
    export_server_keys(folder, server_folder);
    std::cout << "Client keys: ../" << folder << "\nServer keys: ../" << server_folder << '\n';
}

void regenerate_server_keys(const std::string& experiment) {
    FHEController controller;
    const std::string folder = key_folder(experiment);
    controller.parameters_folder = folder;
    controller.load_context(false);
    const auto& layer1_keys = fhe_rotation_keys::find("rotations-layer1.bin");
    controller.generate_bootstrapping_and_rotation_keys(
        layer1_keys.application_rotations, layer1_keys.bootstrap_slots, true,
        layer1_keys.filename);
    controller.clear_context(16384);
    controller.load_context(false);
    const auto& layer2_downsample_keys =
        fhe_rotation_keys::find("rotations-layer2-downsample.bin");
    controller.generate_rotation_keys(layer2_downsample_keys.application_rotations, true,
                                      layer2_downsample_keys.filename);
    export_server_keys(folder, "server_keys_exp" + experiment);
    std::cout << "Required server evaluation keys regenerated.\n";
}

void encrypt_image(const std::string& experiment, const std::string& image, const std::string& output) {
    FHEController controller;
    controller.parameters_folder = key_folder(experiment);
    controller.load_context(false);
    Ctxt ciphertext = controller.encrypt(read_image(image), controller.circuit_depth - 4 - get_relu_depth(controller.relu_degree));
    const fs::path parent = fs::path(output).parent_path();
    if (!parent.empty()) fs::create_directories(parent);
    if (!Serial::SerializeToFile(output, ciphertext, SerType::BINARY)) {
        throw std::runtime_error("Cannot serialize ciphertext to: " + output);
    }
    std::cout << "Encrypted image saved to " << output << '\n';
}

void decrypt_result(const std::string& experiment, const std::string& input) {
    FHEController controller;
    controller.parameters_folder = key_folder(experiment);
    controller.load_context(false);
    Ctxt ciphertext;
    if (!Serial::DeserializeFromFile(input, ciphertext, SerType::BINARY)) {
        throw std::runtime_error("Cannot deserialize ciphertext: " + input);
    }
    const auto logits = controller.decrypt_tovector(ciphertext, 2);
    const auto prediction = static_cast<int>(std::distance(logits.begin(), std::max_element(logits.begin(), logits.end())));
    std::cout << "Handgun: " << logits[0] << "\nKnife: " << logits[1]
              << "\nPrediction: " << utils::get_class(prediction) << '\n';
}

} // namespace

int main(int argc, char** argv) {
    try {
        if (argc < 2) { usage(); return 1; }
        const std::string command = argv[1];
        if (command == "generate_keys" && argc == 3) generate_keys(argv[2]);
        else if (command == "regenerate_server_keys" && argc == 3) regenerate_server_keys(argv[2]);
        else if (command == "encrypt" && argc == 5) encrypt_image(argv[2], argv[3], argv[4]);
        else if (command == "decrypt" && argc == 4) decrypt_result(argv[2], argv[3]);
        else { usage(); return 1; }
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "Error: " << error.what() << '\n';
        return 1;
    }
}
