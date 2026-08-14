#include <iostream>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <vector>

#include "FHEController.h"
#include "Profiler.h"

#define GREEN_TEXT "\033[1;32m"
#define RED_TEXT "\033[1;31m"
#define RESET_COLOR "\033[0m"


void check_arguments(int argc, char *argv[]);
void executeResNet20();
void executeResNet20Batch();

Ctxt initial_layer(const Ctxt& in);
Ctxt layer1(const Ctxt& in);
Ctxt layer2(const Ctxt& in);
Ctxt layer3(const Ctxt& in);
Ctxt final_layer(const Ctxt& in, bool load_keys = true);

struct TransitionCiphertexts {
    Ctxt sx0;
    Ctxt sx1;
    Ctxt dx0;
    Ctxt dx1;
};

struct DownsampledCiphertexts {
    Ctxt sx;
    Ctxt dx;
};

TransitionCiphertexts prepare_layer2_transition(const Ctxt& in);
DownsampledCiphertexts downsample_layer2_transition(const TransitionCiphertexts& in);
Ctxt finish_layer2(const DownsampledCiphertexts& in);
TransitionCiphertexts prepare_layer3_transition(const Ctxt& in);
DownsampledCiphertexts downsample_layer3_transition(const TransitionCiphertexts& in);
Ctxt finish_layer3(const DownsampledCiphertexts& in);

FHEController controller;

int generate_context;
string input_filename;
string output_filename;
string batch_manifest_filename;
string batch_checkpoint_directory;
string batch_metrics_filename;
int verbose;
bool test;
bool plain;
bool batch_mode;

/*
 * TODO:
 * 1) Migliorare convbn sfruttando tutti gli slot del ciphertext
 */

int main(int argc, char *argv[]) {
    //TODO: possibile che il bootstrap a 8192 ci metta lo stesso tempo? indaga

    check_arguments(argc, argv);
    OperationProfiler& profiler = OperationProfiler::instance();
    try {
        profiler.configureFromEnvironment();
        {
            ProfileScope total_profile("pipeline", "total_infer_command", "pipeline", "");
            controller.load_server_context(verbose > 1);
            if (batch_mode) {
                executeResNet20Batch();
            } else {
                executeResNet20();
            }
        }
        profiler.finalize("passed");
        return 0;
    } catch (const std::exception& error) {
        try {
            profiler.finalize("failed", error.what());
        } catch (const std::exception& report_error) {
            cerr << "Profiler report failure: " << report_error.what() << endl;
        }
        cerr << error.what() << endl;
        return 1;
    }
}

namespace {
struct BatchJob {
    size_t index = 0;
    filesystem::path input;
    filesystem::path output;
    filesystem::path checkpoint_directory;
    double layer1_seconds = 0.0;
    double layer2_seconds = 0.0;
    double layer3_seconds = 0.0;
    double final_seconds = 0.0;
};

string trimCarriageReturn(string value) {
    if (!value.empty() && value.back() == '\r') value.pop_back();
    return value;
}

vector<BatchJob> readBatchManifest() {
    ifstream manifest(batch_manifest_filename);
    if (!manifest.is_open()) {
        throw runtime_error("Cannot open batch manifest: " + batch_manifest_filename);
    }

    vector<BatchJob> jobs;
    string line;
    size_t line_number = 0;
    while (getline(manifest, line)) {
        ++line_number;
        line = trimCarriageReturn(line);
        if (line.empty() || line[0] == '#') continue;
        const auto separator = line.find('\t');
        if (separator == string::npos || line.find('\t', separator + 1) != string::npos) {
            throw runtime_error("Batch manifest line " + to_string(line_number) +
                                " must contain exactly one tab");
        }
        const string input = line.substr(0, separator);
        const string output = line.substr(separator + 1);
        if (input.empty() || output.empty()) {
            throw runtime_error("Batch manifest line " + to_string(line_number) +
                                " contains an empty path");
        }
        if (!filesystem::is_regular_file(input)) {
            throw runtime_error("Batch ciphertext does not exist: " + input);
        }
        BatchJob job;
        job.index = jobs.size() + 1;
        job.input = input;
        job.output = output;
        ostringstream name;
        name << "image-" << setw(2) << setfill('0') << job.index;
        job.checkpoint_directory = filesystem::path(batch_checkpoint_directory) / name.str();
        jobs.push_back(std::move(job));
    }
    if (jobs.empty()) throw runtime_error("Batch manifest contains no jobs");
    return jobs;
}

void serializeCiphertext(const filesystem::path& path, const Ctxt& value,
                         const string& event_name) {
    filesystem::create_directories(path.parent_path());
    ProfileScope profile("checkpoint_io", event_name);
    profile.setFile(path.string());
    if (!Serial::SerializeToFile(path.string(), value, SerType::BINARY)) {
        profile.fail();
        throw runtime_error("Cannot serialize ciphertext checkpoint: " + path.string());
    }
}

Ctxt deserializeCiphertext(const filesystem::path& path, const string& event_name) {
    Ctxt value;
    ProfileScope profile("checkpoint_io", event_name);
    profile.setFile(path.string());
    if (!Serial::DeserializeFromFile(path.string(), value, SerType::BINARY)) {
        profile.fail();
        throw runtime_error("Cannot deserialize ciphertext checkpoint: " + path.string());
    }
    return value;
}

void removeCheckpoint(const filesystem::path& path) {
    error_code error;
    filesystem::remove(path, error);
    if (error) throw runtime_error("Cannot remove ciphertext checkpoint " + path.string() +
                                   ": " + error.message());
}

double elapsedSeconds(const steady_clock::time_point& started) {
    return duration<double>(steady_clock::now() - started).count();
}

void saveTransition(const BatchJob& job, const string& prefix,
                    const TransitionCiphertexts& value) {
    serializeCiphertext(job.checkpoint_directory / (prefix + "-sx0.bin"), value.sx0,
                        prefix + "_sx0_serialization");
    serializeCiphertext(job.checkpoint_directory / (prefix + "-sx1.bin"), value.sx1,
                        prefix + "_sx1_serialization");
    serializeCiphertext(job.checkpoint_directory / (prefix + "-dx0.bin"), value.dx0,
                        prefix + "_dx0_serialization");
    serializeCiphertext(job.checkpoint_directory / (prefix + "-dx1.bin"), value.dx1,
                        prefix + "_dx1_serialization");
}

TransitionCiphertexts loadTransition(const BatchJob& job, const string& prefix) {
    TransitionCiphertexts value;
    value.sx0 = deserializeCiphertext(job.checkpoint_directory / (prefix + "-sx0.bin"),
                                      prefix + "_sx0_deserialization");
    value.sx1 = deserializeCiphertext(job.checkpoint_directory / (prefix + "-sx1.bin"),
                                      prefix + "_sx1_deserialization");
    value.dx0 = deserializeCiphertext(job.checkpoint_directory / (prefix + "-dx0.bin"),
                                      prefix + "_dx0_deserialization");
    value.dx1 = deserializeCiphertext(job.checkpoint_directory / (prefix + "-dx1.bin"),
                                      prefix + "_dx1_deserialization");
    return value;
}

void removeTransition(const BatchJob& job, const string& prefix) {
    for (const char* suffix : {"-sx0.bin", "-sx1.bin", "-dx0.bin", "-dx1.bin"}) {
        removeCheckpoint(job.checkpoint_directory / (prefix + suffix));
    }
}

void saveDownsampled(const BatchJob& job, const string& prefix,
                     const DownsampledCiphertexts& value) {
    serializeCiphertext(job.checkpoint_directory / (prefix + "-sx.bin"), value.sx,
                        prefix + "_sx_serialization");
    serializeCiphertext(job.checkpoint_directory / (prefix + "-dx.bin"), value.dx,
                        prefix + "_dx_serialization");
}

DownsampledCiphertexts loadDownsampled(const BatchJob& job, const string& prefix) {
    DownsampledCiphertexts value;
    value.sx = deserializeCiphertext(job.checkpoint_directory / (prefix + "-sx.bin"),
                                     prefix + "_sx_deserialization");
    value.dx = deserializeCiphertext(job.checkpoint_directory / (prefix + "-dx.bin"),
                                     prefix + "_dx_deserialization");
    return value;
}

void removeDownsampled(const BatchJob& job, const string& prefix) {
    removeCheckpoint(job.checkpoint_directory / (prefix + "-sx.bin"));
    removeCheckpoint(job.checkpoint_directory / (prefix + "-dx.bin"));
}
}  // namespace

void executeResNet20Batch() {
    vector<BatchJob> jobs = readBatchManifest();
    const filesystem::path checkpoint_root(batch_checkpoint_directory);
    if (checkpoint_root.empty() || checkpoint_root == checkpoint_root.root_path()) {
        throw runtime_error("Unsafe batch checkpoint directory");
    }
    filesystem::create_directories(checkpoint_root);
    if (!filesystem::is_empty(checkpoint_root)) {
        throw runtime_error("Batch checkpoint directory must be empty: " +
                            checkpoint_root.string());
    }
    for (const auto& job : jobs) filesystem::create_directories(job.checkpoint_directory);

    if (verbose >= 0) {
        cout << "Encrypted ResNet20 staged batch started for " << jobs.size() << " images." << endl;
    }
    const auto batch_started = steady_clock::now();
    ProfileScope circuit_profile("pipeline", "fhe_circuit", "Batch", "");

    controller.load_bootstrapping_and_rotation_keys("rotations-layer1.bin", 16384, verbose > 1);

    for (auto& job : jobs) {
        const auto started = steady_clock::now();
        Ctxt input = deserializeCiphertext(job.input, "batch_encrypted_input_deserialization");
        Ctxt result = layer1(initial_layer(input));
        serializeCiphertext(job.checkpoint_directory / "layer1.bin", result,
                            "batch_layer1_serialization");
        job.layer1_seconds += elapsedSeconds(started);
        cout << "[batch " << job.index << '/' << jobs.size() << "] layer1 complete" << endl;
    }

    for (auto& job : jobs) {
        const auto started = steady_clock::now();
        Ctxt input = deserializeCiphertext(job.checkpoint_directory / "layer1.bin",
                                           "batch_layer1_deserialization");
        saveTransition(job, "layer2-transition", prepare_layer2_transition(input));
        removeCheckpoint(job.checkpoint_directory / "layer1.bin");
        job.layer2_seconds += elapsedSeconds(started);
    }

    controller.clear_bootstrapping_and_rotation_keys(16384);
    controller.load_rotation_keys("rotations-layer2-downsample.bin", verbose > 1);
    for (auto& job : jobs) {
        const auto started = steady_clock::now();
        saveDownsampled(job, "layer2-downsampled",
                        downsample_layer2_transition(loadTransition(job, "layer2-transition")));
        removeTransition(job, "layer2-transition");
        job.layer2_seconds += elapsedSeconds(started);
    }

    controller.clear_rotation_keys();
    controller.load_bootstrapping_and_rotation_keys("rotations-layer2.bin", 8192, verbose > 1);
    for (auto& job : jobs) {
        const auto started = steady_clock::now();
        Ctxt result = finish_layer2(loadDownsampled(job, "layer2-downsampled"));
        serializeCiphertext(job.checkpoint_directory / "layer2.bin", result,
                            "batch_layer2_serialization");
        removeDownsampled(job, "layer2-downsampled");
        job.layer2_seconds += elapsedSeconds(started);
        cout << "[batch " << job.index << '/' << jobs.size() << "] layer2 complete" << endl;
    }

    for (auto& job : jobs) {
        const auto started = steady_clock::now();
        Ctxt input = deserializeCiphertext(job.checkpoint_directory / "layer2.bin",
                                           "batch_layer2_deserialization");
        saveTransition(job, "layer3-transition", prepare_layer3_transition(input));
        removeCheckpoint(job.checkpoint_directory / "layer2.bin");
        job.layer3_seconds += elapsedSeconds(started);
    }

    controller.clear_bootstrapping_and_rotation_keys(8192);
    controller.load_rotation_keys("rotations-layer3-downsample.bin", verbose > 1);
    for (auto& job : jobs) {
        const auto started = steady_clock::now();
        saveDownsampled(job, "layer3-downsampled",
                        downsample_layer3_transition(loadTransition(job, "layer3-transition")));
        removeTransition(job, "layer3-transition");
        job.layer3_seconds += elapsedSeconds(started);
    }

    controller.clear_rotation_keys();
    controller.load_bootstrapping_and_rotation_keys("rotations-layer3.bin", 4096, verbose > 1);
    for (auto& job : jobs) {
        const auto started = steady_clock::now();
        Ctxt result = finish_layer3(loadDownsampled(job, "layer3-downsampled"));
        serializeCiphertext(job.checkpoint_directory / "layer3.bin", result,
                            "batch_layer3_serialization");
        removeDownsampled(job, "layer3-downsampled");
        job.layer3_seconds += elapsedSeconds(started);
        cout << "[batch " << job.index << '/' << jobs.size() << "] layer3 complete" << endl;
    }

    controller.clear_bootstrapping_and_rotation_keys(4096);
    controller.load_rotation_keys("rotations-finallayer.bin", verbose > 1);
    for (auto& job : jobs) {
        const auto started = steady_clock::now();
        Ctxt input = deserializeCiphertext(job.checkpoint_directory / "layer3.bin",
                                           "batch_layer3_deserialization");
        Ctxt result = final_layer(input, false);
        serializeCiphertext(job.output, result, "batch_result_serialization");
        removeCheckpoint(job.checkpoint_directory / "layer3.bin");
        job.final_seconds = elapsedSeconds(started);
        error_code error;
        filesystem::remove(job.checkpoint_directory, error);
        if (error) throw runtime_error("Cannot remove checkpoint directory: " + error.message());
        cout << "Encrypted result saved to " << job.output << endl;
    }

    circuit_profile.finish();
    const auto metrics_parent = filesystem::path(batch_metrics_filename).parent_path();
    if (!metrics_parent.empty()) filesystem::create_directories(metrics_parent);
    ofstream metrics(batch_metrics_filename);
    if (!metrics.is_open()) throw runtime_error("Cannot write batch metrics: " + batch_metrics_filename);
    metrics << "index\tinput\toutput\tcircuit_seconds\tlayer1_seconds\tlayer2_seconds\t"
               "layer3_seconds\tfinal_seconds\n";
    metrics << fixed << setprecision(6);
    for (const auto& job : jobs) {
        const double circuit = job.layer1_seconds + job.layer2_seconds +
                               job.layer3_seconds + job.final_seconds;
        metrics << job.index << '\t' << job.input.string() << '\t' << job.output.string() << '\t'
                << circuit << '\t' << job.layer1_seconds << '\t' << job.layer2_seconds << '\t'
                << job.layer3_seconds << '\t' << job.final_seconds << '\n';
    }
    if (!metrics) throw runtime_error("Cannot finish batch metrics: " + batch_metrics_filename);
    if (verbose > 0) {
        cout << "Staged batch wall time: " << fixed << setprecision(3)
             << elapsedSeconds(batch_started) << "s" << endl;
    }
}

void executeResNet20() {
    if (verbose >= 0) cout << "Encrypted ResNet20 classification started." << endl;

    Ctxt firstLayer, resLayer1, resLayer2, resLayer3, finalRes;

    // The server has no secret key, therefore it must never print/decrypt
    // intermediate ciphertext values.
    const bool print_intermediate_values = false;
    const bool print_bootstrap_precision = false;

    Ctxt in;
    {
        ProfileScope profile("io", "encrypted_input_deserialization", "pipeline", "");
        profile.setFile(input_filename);
        if (!Serial::DeserializeFromFile(input_filename, in, SerType::BINARY)) {
            profile.fail();
            throw runtime_error("Cannot deserialize encrypted input: " + input_filename);
        }
    }

    controller.load_bootstrapping_and_rotation_keys("rotations-layer1.bin", 16384, verbose > 1);

    if (print_bootstrap_precision){
        cout << "Bootstrap precision test is disabled on the server (no encryption/decryption key)." << endl;
    }

    auto start = start_time();
    ProfileScope circuit_profile("pipeline", "fhe_circuit", "pipeline", "");

    firstLayer = initial_layer(in);
    if (print_intermediate_values) controller.print(firstLayer, 16384, "Initial layer: ");
  
    /*
     * Layer 1: 16 channels of 32x32
     */
    auto startLayer = start_time();
    {
        ProfileScope layer_profile("layer", "layer_1", "Layer 1", "");
        resLayer1 = layer1(firstLayer);
        Serial::SerializeToFile("../checkpoints/layer1.bin", resLayer1, SerType::BINARY);
    }
    if (print_intermediate_values) controller.print(resLayer1, 16384, "Layer 1: ");
    if (verbose > 0) print_duration(startLayer, "Layer 1 took:");

    /*
     * Layer 2: 32 channels of 16x16
     */
    startLayer = start_time();
    {
        ProfileScope layer_profile("layer", "layer_2", "Layer 2", "");
        Serial::DeserializeFromFile("../checkpoints/layer1.bin", resLayer1, SerType::BINARY);
        resLayer2 = layer2(resLayer1);
        Serial::SerializeToFile("../checkpoints/layer2.bin", resLayer2, SerType::BINARY);
    }
    if (print_intermediate_values) controller.print(resLayer2, 8192, "Layer 2: ");
    if (verbose > 0) print_duration(startLayer, "Layer 2 took:");

    /*
     * Layer 2: 64 channels of 8x8
     */
    startLayer = start_time();
    {
        ProfileScope layer_profile("layer", "layer_3", "Layer 3", "");
        Serial::DeserializeFromFile("../checkpoints/layer2.bin", resLayer2, SerType::BINARY);
        resLayer3 = layer3(resLayer2);
        Serial::SerializeToFile("../checkpoints/layer3.bin", resLayer3, SerType::BINARY);
    }
    if (print_intermediate_values) controller.print(resLayer3, 4096, "Layer 3: ");
    if (verbose > 0) print_duration(startLayer, "Layer 3 took:");


    Serial::DeserializeFromFile("../checkpoints/layer3.bin", resLayer3, SerType::BINARY);
    finalRes = final_layer(resLayer3);
    const auto output_parent = std::filesystem::path(output_filename).parent_path();
    if (!output_parent.empty()) std::filesystem::create_directories(output_parent);
    {
        ProfileScope profile("io", "result_serialization", "Final", "");
        profile.setFile(output_filename);
        if (!Serial::SerializeToFile(output_filename, finalRes, SerType::BINARY)) {
            profile.fail();
            throw runtime_error("Cannot serialize encrypted result: " + output_filename);
        }
        profile.setFile(output_filename);
    }
    cout << "Encrypted result saved to " << output_filename << endl;

    if (verbose > 0) print_duration_yellow(start, "The evaluation of the whole circuit took: ");
}

Ctxt initial_layer(const Ctxt& in) {
    ProfileContextScope context("Initial", "");
    ProfileScope layer_profile("layer", "initial_layer", "Initial", "");
    double scale = 0.90;

    Ctxt res = controller.convbn_initial(in, scale, verbose > 1);
    res = controller.relu(res, scale, verbose > 1);

    return res;
}

Ctxt final_layer(const Ctxt& in, bool load_keys) {
    ProfileContextScope context("Final", "");
    ProfileScope layer_profile("layer", "final_layer", "Final", "");
    if (load_keys) {
        controller.clear_bootstrapping_and_rotation_keys(4096);
        controller.load_rotation_keys("rotations-finallayer.bin", false);
    }

    controller.num_slots = 4096;

    Ptxt weight = controller.encode(read_fc_weight("../weights/fc.bin"), in->GetLevel(), controller.num_slots);
    Ptxt bias = controller.encode(read_fc_bias("../weights/fc_bias.bin"), in->GetLevel(), controller.num_slots);

    Ctxt res = controller.rotsum(in, 64);
    res = controller.mult(res, controller.mask_mod(64, res->GetLevel(), 1.0 / 64.0));

    //Two classes are needed; 16 repetitions are retained because repeat is exponential.
    res = controller.repeat(res, 16);
    res = controller.mult(res, weight);
    res = controller.rotsum_padded(res, 64);
    res = controller.add(res, bias);

    return res;
}

TransitionCiphertexts prepare_layer3_transition(const Ctxt& in) {
    ProfileContextScope context("Layer 3", "Block 1 transition");
    ProfileScope profile("batch_stage", "layer3_transition_prepare");
    const bool timing = verbose > 1;
    Ctxt boot_in = controller.bootstrap(in, timing);
    vector<Ctxt> sx = controller.convbn3264sx(boot_in, 7, 1, 0.63, timing);
    vector<Ctxt> dx = controller.convbn3264dx(boot_in, 7, 1, 0.40, timing);
    return {sx.at(0), sx.at(1), dx.at(0), dx.at(1)};
}

DownsampledCiphertexts downsample_layer3_transition(const TransitionCiphertexts& in) {
    ProfileContextScope context("Layer 3", "Block 1 downsample");
    ProfileScope profile("batch_stage", "layer3_transition_downsample");
    return {controller.downsample256to64(in.sx0, in.sx1),
            controller.downsample256to64(in.dx0, in.dx1)};
}

Ctxt finish_layer3(const DownsampledCiphertexts& in) {
    const bool timing = verbose > 1;
    ProfileContextScope block1_context("Layer 3", "Block 1");
    ProfileScope block1_profile("block", "layer_3_block_1_finish", "Layer 3", "Block 1");
    Ctxt fullpackSx = in.sx;
    Ctxt fullpackDx = in.dx;
    controller.num_slots = 4096;
    fullpackSx = controller.bootstrap(fullpackSx, timing);
    fullpackSx = controller.relu(fullpackSx, 0.63, timing);
    fullpackSx = controller.convbn3(fullpackSx, 7, 2, 0.40, timing);
    Ctxt res1;
    {
        ProfileScope residual_profile("residual", "layer_3_block_1_residual_add");
        res1 = controller.add(fullpackSx, fullpackDx);
    }
    res1 = controller.bootstrap(res1, timing);
    res1 = controller.relu(res1, 0.40, timing);
    block1_profile.finish();
    block1_context.restore();

    ProfileContextScope block2_context("Layer 3", "Block 2");
    ProfileScope block2_profile("block", "layer_3_block_2", "Layer 3", "Block 2");
    Ctxt res2 = controller.convbn3(res1, 8, 1, 0.57, timing);
    res2 = controller.bootstrap(res2, timing);
    res2 = controller.relu(res2, 0.57, timing);
    res2 = controller.convbn3(res2, 8, 2, 0.33, timing);
    {
        ProfileScope residual_profile("residual", "layer_3_block_2_residual_add");
        res2 = controller.add(res2, controller.mult(res1, 0.33));
    }
    res2 = controller.bootstrap(res2, timing);
    res2 = controller.relu(res2, 0.33, timing);
    block2_profile.finish();
    block2_context.restore();

    ProfileContextScope block3_context("Layer 3", "Block 3");
    ProfileScope block3_profile("block", "layer_3_block_3", "Layer 3", "Block 3");
    Ctxt res3 = controller.convbn3(res2, 9, 1, 0.69, timing);
    res3 = controller.bootstrap(res3, timing);
    res3 = controller.relu(res3, 0.69, timing);
    res3 = controller.convbn3(res3, 9, 2, 0.10, timing);
    {
        ProfileScope residual_profile("residual", "layer_3_block_3_residual_add");
        res3 = controller.add(res3, controller.mult(res2, 0.10));
    }
    res3 = controller.bootstrap(res3, timing);
    res3 = controller.relu(res3, 0.10, timing);
    res3 = controller.bootstrap(res3, timing);
    return res3;
}

Ctxt layer3(const Ctxt& in) {
    TransitionCiphertexts transition = prepare_layer3_transition(in);
    controller.clear_bootstrapping_and_rotation_keys(8192);
    controller.load_rotation_keys("rotations-layer3-downsample.bin", verbose > 1);
    DownsampledCiphertexts downsampled = downsample_layer3_transition(transition);
    controller.clear_rotation_keys();
    controller.load_bootstrapping_and_rotation_keys("rotations-layer3.bin", 4096, verbose > 1);
    return finish_layer3(downsampled);
}

TransitionCiphertexts prepare_layer2_transition(const Ctxt& in) {
    ProfileContextScope context("Layer 2", "Block 1 transition");
    ProfileScope profile("batch_stage", "layer2_transition_prepare");
    const bool timing = verbose > 1;
    Ctxt boot_in = controller.bootstrap(in, timing);
    vector<Ctxt> sx = controller.convbn1632sx(boot_in, 4, 1, 0.57, timing);
    vector<Ctxt> dx = controller.convbn1632dx(boot_in, 4, 1, 0.40, timing);
    return {sx.at(0), sx.at(1), dx.at(0), dx.at(1)};
}

DownsampledCiphertexts downsample_layer2_transition(const TransitionCiphertexts& in) {
    ProfileContextScope context("Layer 2", "Block 1 downsample");
    ProfileScope profile("batch_stage", "layer2_transition_downsample");
    return {controller.downsample1024to256(in.sx0, in.sx1),
            controller.downsample1024to256(in.dx0, in.dx1)};
}

Ctxt finish_layer2(const DownsampledCiphertexts& in) {
    const bool timing = verbose > 1;
    ProfileContextScope block1_context("Layer 2", "Block 1");
    ProfileScope block1_profile("block", "layer_2_block_1_finish", "Layer 2", "Block 1");
    Ctxt fullpackSx = in.sx;
    Ctxt fullpackDx = in.dx;
    controller.num_slots = 8192;
    fullpackSx = controller.bootstrap(fullpackSx, timing);
    fullpackSx = controller.relu(fullpackSx, 0.57, timing);
    fullpackSx = controller.convbn2(fullpackSx, 4, 2, 0.40, timing);
    Ctxt res1;
    {
        ProfileScope residual_profile("residual", "layer_2_block_1_residual_add");
        res1 = controller.add(fullpackSx, fullpackDx);
    }
    res1 = controller.bootstrap(res1, timing);
    res1 = controller.relu(res1, 0.40, timing);
    block1_profile.finish();
    block1_context.restore();

    ProfileContextScope block2_context("Layer 2", "Block 2");
    ProfileScope block2_profile("block", "layer_2_block_2", "Layer 2", "Block 2");
    Ctxt res2 = controller.convbn2(res1, 5, 1, 0.76, timing);
    res2 = controller.bootstrap(res2, timing);
    res2 = controller.relu(res2, 0.76, timing);
    res2 = controller.convbn2(res2, 5, 2, 0.37, timing);
    {
        ProfileScope residual_profile("residual", "layer_2_block_2_residual_add");
        res2 = controller.add(res2, controller.mult(res1, 0.37));
    }
    res2 = controller.bootstrap(res2, timing);
    res2 = controller.relu(res2, 0.37, timing);
    block2_profile.finish();
    block2_context.restore();

    ProfileContextScope block3_context("Layer 2", "Block 3");
    ProfileScope block3_profile("block", "layer_2_block_3", "Layer 2", "Block 3");
    Ctxt res3 = controller.convbn2(res2, 6, 1, 0.63, timing);
    res3 = controller.bootstrap(res3, timing);
    res3 = controller.relu(res3, 0.63, timing);
    res3 = controller.convbn2(res3, 6, 2, 0.25, timing);
    {
        ProfileScope residual_profile("residual", "layer_2_block_3_residual_add");
        res3 = controller.add(res3, controller.mult(res2, 0.25));
    }
    res3 = controller.bootstrap(res3, timing);
    res3 = controller.relu(res3, 0.25, timing);
    return res3;
}

Ctxt layer2(const Ctxt& in) {
    TransitionCiphertexts transition = prepare_layer2_transition(in);
    controller.clear_bootstrapping_and_rotation_keys(16384);
    controller.load_rotation_keys("rotations-layer2-downsample.bin", verbose > 1);
    DownsampledCiphertexts downsampled = downsample_layer2_transition(transition);
    controller.clear_rotation_keys();
    controller.load_bootstrapping_and_rotation_keys("rotations-layer2.bin", 8192, verbose > 1);
    return finish_layer2(downsampled);
}

Ctxt layer1(const Ctxt& in) {
    bool timing = verbose > 1;
    double scale = 1.00;


    if (verbose > 1) cout << "---Start: Layer1 - Block 1---" << endl;
    ProfileContextScope block1_context("Layer 1", "Block 1");
    ProfileScope block1_profile("block", "layer_1_block_1", "Layer 1", "Block 1");
    auto start = start_time();
    Ctxt res1;
    res1 = controller.convbn(in, 1, 1, scale, timing);
    res1 = controller.bootstrap(res1, timing);
    res1 = controller.relu(res1, scale, timing);

    scale = 0.52;

    res1 = controller.convbn(res1, 1, 2, scale, timing);
    {
        ProfileScope residual_profile("residual", "layer_1_block_1_residual_add");
        res1 = controller.add(res1, controller.mult(in, scale));
    }
    res1 = controller.bootstrap(res1, timing);
    res1 = controller.relu(res1, scale, timing);
    if (verbose > 1) print_duration(start, "Total");
    if (verbose > 1) cout << "---End  : Layer1 - Block 1---" << endl;
    block1_profile.finish();
    block1_context.restore();

    scale = 0.55;


    if (verbose > 1) cout << "---Start: Layer1 - Block 2---" << endl;
    ProfileContextScope block2_context("Layer 1", "Block 2");
    ProfileScope block2_profile("block", "layer_1_block_2", "Layer 1", "Block 2");
    start = start_time();
    Ctxt res2;
    res2 = controller.convbn(res1, 2, 1, scale, timing);
    res2 = controller.bootstrap(res2, timing);
    res2 = controller.relu(res2, scale, timing);

    scale = 0.36;

    res2 = controller.convbn(res2, 2, 2, scale, timing);
    {
        ProfileScope residual_profile("residual", "layer_1_block_2_residual_add");
        res2 = controller.add(res2, controller.mult(res1, scale));
    }
    res2 = controller.bootstrap(res2, timing);
    res2 = controller.relu(res2, scale, timing);
    if (verbose > 1) print_duration(start, "Total");
    if (verbose > 1) cout << "---End  : Layer1 - Block 2---" << endl;
    block2_profile.finish();
    block2_context.restore();
  
    scale = 0.63;

    if (verbose > 1) cout << "---Start: Layer1 - Block 3---" << endl;
    ProfileContextScope block3_context("Layer 1", "Block 3");
    ProfileScope block3_profile("block", "layer_1_block_3", "Layer 1", "Block 3");
    start = start_time();
    Ctxt res3;
    res3 = controller.convbn(res2, 3, 1, scale, timing);
    res3 = controller.bootstrap(res3, timing);
    res3 = controller.relu(res3, scale, timing);

    scale = 0.42;
  
    res3 = controller.convbn(res3, 3, 2, scale, timing);
    {
        ProfileScope residual_profile("residual", "layer_1_block_3_residual_add");
        res3 = controller.add(res3, controller.mult(res2, scale));
    }
    res3 = controller.bootstrap(res3, timing);
    res3 = controller.relu(res3, scale, timing);

    if (verbose > 1) print_duration(start, "Total");
    if (verbose > 1) cout << "---End  : Layer1 - Block 3---" << endl;
    block3_profile.finish();
    block3_context.restore();

    return res3;
}

void check_arguments(int argc, char *argv[]) {
    verbose = 0;
    batch_mode = false;
    if (argc < 2 || (string(argv[1]) != "infer" && string(argv[1]) != "infer_batch")) {
        cerr << "Usage:\n"
             << "  FHEServer infer <experiment> <encrypted-input> <encrypted-output> [verbose]\n"
             << "  FHEServer infer_batch <experiment> <batch-manifest> <checkpoint-dir> "
                "<metrics-output> [verbose]\n";
        exit(1);
    }
    batch_mode = string(argv[1]) == "infer_batch";
    if ((!batch_mode && argc < 5) || (batch_mode && argc < 6)) {
        cerr << "Missing arguments for " << argv[1] << ". Run FHEServer without arguments for usage.\n";
        exit(1);
    }
    const string experiment = argv[2];
    if (experiment != "1" && experiment != "2" && experiment != "3" && experiment != "4") {
        cerr << "Experiment must be 1, 2, 3, or 4.\n";
        exit(1);
    }
    controller.parameters_folder = "keys_exp" + experiment;
    if (batch_mode) {
        batch_manifest_filename = argv[3];
        batch_checkpoint_directory = argv[4];
        batch_metrics_filename = argv[5];
        if (argc > 6) verbose = atoi(argv[6]);
    } else {
        input_filename = argv[3];
        output_filename = argv[4];
        if (argc > 5) verbose = atoi(argv[5]);
    }
}
