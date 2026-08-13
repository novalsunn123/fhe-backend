#include <iostream>
#include <filesystem>
#include <stdexcept>

#include "FHEController.h"
#include "Profiler.h"

#define GREEN_TEXT "\033[1;32m"
#define RED_TEXT "\033[1;31m"
#define RESET_COLOR "\033[0m"


void check_arguments(int argc, char *argv[]);
void executeResNet20();

Ctxt initial_layer(const Ctxt& in);
Ctxt layer1(const Ctxt& in);
Ctxt layer2(const Ctxt& in);
Ctxt layer3(const Ctxt& in);
Ctxt final_layer(const Ctxt& in);

FHEController controller;

int generate_context;
string input_filename;
string output_filename;
int verbose;
bool test;
bool plain;

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
            executeResNet20();
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

Ctxt final_layer(const Ctxt& in) {
    ProfileContextScope context("Final", "");
    ProfileScope layer_profile("layer", "final_layer", "Final", "");
    controller.clear_bootstrapping_and_rotation_keys(4096);
    controller.load_rotation_keys("rotations-finallayer.bin", false);

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

Ctxt layer3(const Ctxt& in) {
    double scaleSx = 0.63;
    double scaleDx = 0.40;

    bool timing = verbose > 1;

    if (verbose > 1) cout << "---Start: Layer3 - Block 1---" << endl;
    ProfileContextScope block1_context("Layer 3", "Block 1");
    ProfileScope block1_profile("block", "layer_3_block_1", "Layer 3", "Block 1");
    auto start = start_time();
    Ctxt boot_in = controller.bootstrap(in, timing);

    vector<Ctxt> res1sx = controller.convbn3264sx(boot_in, 7, 1, scaleSx, timing); //Questo è lento
    vector<Ctxt> res1dx = controller.convbn3264dx(boot_in, 7, 1, scaleDx, timing); //Questo è lento

    controller.clear_bootstrapping_and_rotation_keys(8192);
    controller.load_rotation_keys("rotations-layer3-downsample.bin", timing);

    //N.B. questo downsampling usa un chain index in meno - posso accelerare convbn3264sx
    Ctxt fullpackSx = controller.downsample256to64(res1sx[0], res1sx[1]);
    Ctxt fullpackDx = controller.downsample256to64(res1dx[0], res1dx[1]);
    res1sx.clear();
    res1dx.clear();

    controller.clear_rotation_keys();
    controller.load_bootstrapping_and_rotation_keys("rotations-layer3.bin", 4096, verbose > 1);

    controller.num_slots = 4096;
    fullpackSx = controller.bootstrap(fullpackSx, timing);

    fullpackSx = controller.relu(fullpackSx, scaleSx, timing);
    fullpackSx = controller.convbn3(fullpackSx, 7, 2, scaleDx, timing);
    Ctxt res1;
    {
        ProfileScope residual_profile("residual", "layer_3_block_1_residual_add");
        res1 = controller.add(fullpackSx, fullpackDx);
    }
    res1 = controller.bootstrap(res1, timing);
    res1 = controller.relu(res1, scaleDx, timing);
    if (verbose > 1) print_duration(start, "Total");
    if (verbose > 1) cout << "---End  : Layer3 - Block 1---" << endl;
    block1_profile.finish();
    block1_context.restore();

    double scale = 0.57;


    if (verbose > 1) cout << "---Start: Layer3 - Block 2---" << endl;
    ProfileContextScope block2_context("Layer 3", "Block 2");
    ProfileScope block2_profile("block", "layer_3_block_2", "Layer 3", "Block 2");
    start = start_time();
    Ctxt res2;
    res2 = controller.convbn3(res1, 8, 1, scale, timing);
    res2 = controller.bootstrap(res2, timing);
    res2 = controller.relu(res2, scale, timing);

    scale = 0.33;

    res2 = controller.convbn3(res2, 8, 2, scale, timing);
    {
        ProfileScope residual_profile("residual", "layer_3_block_2_residual_add");
        res2 = controller.add(res2, controller.mult(res1, scale));
    }
    res2 = controller.bootstrap(res2, timing);
    res2 = controller.relu(res2, scale, timing);
    if (verbose > 1) print_duration(start, "Total");
    if (verbose > 1) cout << "---End  : Layer3 - Block 2---" << endl;
    block2_profile.finish();
    block2_context.restore();

    scale = 0.69;

    if (verbose > 1) cout << "---Start: Layer3 - Block 3---" << endl;
    ProfileContextScope block3_context("Layer 3", "Block 3");
    ProfileScope block3_profile("block", "layer_3_block_3", "Layer 3", "Block 3");
    start = start_time();
    Ctxt res3;

    res3 = controller.convbn3(res2, 9, 1, scale, timing);
    res3 = controller.bootstrap(res3, timing);
    res3 = controller.relu(res3, scale, timing);

    scale = 0.1;

    res3 = controller.convbn3(res3, 9, 2, scale, timing);
    {
        ProfileScope residual_profile("residual", "layer_3_block_3_residual_add");
        res3 = controller.add(res3, controller.mult(res2, scale));
    }
    res3 = controller.bootstrap(res3, timing);
    res3 = controller.relu(res3, scale, timing);
    res3 = controller.bootstrap(res3, timing);

    if (verbose > 1) print_duration(start, "Total");
    if (verbose > 1) cout << "---End  : Layer3 - Block 3---" << endl;
    block3_profile.finish();
    block3_context.restore();


    return res3;
}

Ctxt layer2(const Ctxt& in) {

    double scaleSx = 0.57;
    double scaleDx = 0.40;


    bool timing = verbose > 1;

    if (verbose > 1) cout << "---Start: Layer2 - Block 1---" << endl;
    ProfileContextScope block1_context("Layer 2", "Block 1");
    ProfileScope block1_profile("block", "layer_2_block_1", "Layer 2", "Block 1");
    auto start = start_time();
    Ctxt boot_in = controller.bootstrap(in, timing);

    vector<Ctxt> res1sx = controller.convbn1632sx(boot_in, 4, 1, scaleSx, timing); //Questo è lento

    vector<Ctxt> res1dx = controller.convbn1632dx(boot_in, 4, 1, scaleDx, timing); //Questo è lento


    controller.clear_bootstrapping_and_rotation_keys(16384);
    controller.load_rotation_keys("rotations-layer2-downsample.bin", timing);

    Ctxt fullpackSx = controller.downsample1024to256(res1sx[0], res1sx[1]);
    Ctxt fullpackDx = controller.downsample1024to256(res1dx[0], res1dx[1]);


    res1sx.clear();
    res1dx.clear();

    controller.clear_rotation_keys();
    controller.load_bootstrapping_and_rotation_keys("rotations-layer2.bin", 8192, verbose > 1);

    controller.num_slots = 8192;
    fullpackSx = controller.bootstrap(fullpackSx, timing);

    fullpackSx = controller.relu(fullpackSx, scaleSx, timing);

    //I use the scale of the right branch since they will be added together
    fullpackSx = controller.convbn2(fullpackSx, 4, 2, scaleDx, timing);
    Ctxt res1;
    {
        ProfileScope residual_profile("residual", "layer_2_block_1_residual_add");
        res1 = controller.add(fullpackSx, fullpackDx);
    }
    res1 = controller.bootstrap(res1, timing);
    res1 = controller.relu(res1, scaleDx, timing);
    if (verbose > 1) print_duration(start, "Total");
    if (verbose > 1) cout << "---End  : Layer2 - Block 1---" << endl;
    block1_profile.finish();
    block1_context.restore();

    double scale = 0.76;

    if (verbose > 1) cout << "---Start: Layer2 - Block 2---" << endl;
    ProfileContextScope block2_context("Layer 2", "Block 2");
    ProfileScope block2_profile("block", "layer_2_block_2", "Layer 2", "Block 2");
    start = start_time();
    Ctxt res2;
    res2 = controller.convbn2(res1, 5, 1, scale, timing);
    res2 = controller.bootstrap(res2, timing);
    res2 = controller.relu(res2, scale, timing);

    scale = 0.37;

    res2 = controller.convbn2(res2, 5, 2, scale, timing);
    {
        ProfileScope residual_profile("residual", "layer_2_block_2_residual_add");
        res2 = controller.add(res2, controller.mult(res1, scale));
    }
    res2 = controller.bootstrap(res2, timing);
    res2 = controller.relu(res2, scale, timing);
    if (verbose > 1) print_duration(start, "Total");
    if (verbose > 1) cout << "---End  : Layer2 - Block 2---" << endl;
    block2_profile.finish();
    block2_context.restore();

    scale = 0.63;

    if (verbose > 1) cout << "---Start: Layer2 - Block 3---" << endl;
    ProfileContextScope block3_context("Layer 2", "Block 3");
    ProfileScope block3_profile("block", "layer_2_block_3", "Layer 2", "Block 3");
    start = start_time();
    Ctxt res3;
    res3 = controller.convbn2(res2, 6, 1, scale, timing);
    res3 = controller.bootstrap(res3, timing);
    res3 = controller.relu(res3, scale, timing);
  
    scale = 0.25;

    res3 = controller.convbn2(res3, 6, 2, scale, timing);
    {
        ProfileScope residual_profile("residual", "layer_2_block_3_residual_add");
        res3 = controller.add(res3, controller.mult(res2, scale));
    }
    res3 = controller.bootstrap(res3, timing);
    res3 = controller.relu(res3, scale, timing);
    if (verbose > 1) print_duration(start, "Total");
    if (verbose > 1) cout << "---End  : Layer2 - Block 3---" << endl;
    block3_profile.finish();
    block3_context.restore();

    return res3;
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
    if (argc < 5 || string(argv[1]) != "infer") {
        cerr << "Usage: FHEServer infer <experiment> <encrypted-input> <encrypted-output> [verbose]\n";
        exit(1);
    }
    const string experiment = argv[2];
    if (experiment != "1" && experiment != "2" && experiment != "3" && experiment != "4") {
        cerr << "Experiment must be 1, 2, 3, or 4.\n";
        exit(1);
    }
    controller.parameters_folder = "keys_exp" + experiment;
    input_filename = argv[3];
    output_filename = argv[4];
    if (argc > 5) verbose = atoi(argv[5]);
}
