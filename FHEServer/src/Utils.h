//
// Created by Lorenzo on 24/10/23.
//

#ifndef LOWMEMORYFHERESNET20_UTILS_H
#define LOWMEMORYFHERESNET20_UTILS_H

#include <iostream>
#include <openfhe.h>

#include "Profiler.h"

#define YELLOW_TEXT "\033[1;33m"
#define RESET_COLOR "\033[0m"


using namespace std;
using namespace std::chrono;
using namespace lbcrypto;

namespace utils {

    static inline chrono::time_point<steady_clock, nanoseconds> start_time() {
        return steady_clock::now();
    }

    static duration<long long, ratio<1, 1000>> total_time;

    static inline string get_class(int max_index) {
        switch (max_index) {
            case 0:
                return "Handgun";
            case 1:
                return "Knife";
        }

        return "?";
    }

    static inline void print_duration(chrono::time_point<steady_clock, nanoseconds> start, const string &title) {
        auto ms = duration_cast<milliseconds>(steady_clock::now() - start);

        total_time += ms;

        auto secs = duration_cast<seconds>(ms);
        ms -= duration_cast<milliseconds>(secs);
        auto mins = duration_cast<minutes>(secs);
        secs -= duration_cast<seconds>(mins);

        if (mins.count() < 1) {
            cout << "⌛(" << title << "): " << secs.count() << ":" << ms.count() << "s" << " (Total: " << duration_cast<seconds>(total_time).count() << "s)" << endl;
        } else {
            cout << "⌛(" << title << "): " << mins.count() << "." << secs.count() << ":" << ms.count() << endl;
        }
    }

    static inline void print_duration_yellow(chrono::time_point<steady_clock, nanoseconds> start, const string &title) {
        auto ms = duration_cast<milliseconds>(steady_clock::now() - start);

        total_time += ms;

        auto secs = duration_cast<seconds>(ms);
        ms -= duration_cast<milliseconds>(secs);
        auto mins = duration_cast<minutes>(secs);
        secs -= duration_cast<seconds>(mins);

        if (mins.count() < 1) {
            cout << "⌛(" << title << "): " << secs.count() << ":" << ms.count() << "s" << " (Total: " << duration_cast<seconds>(total_time).count() << "s)" << endl;
        } else {
            cout << "⌛(" << title << "): " << YELLOW_TEXT << mins.count() << "." << secs.count() << ":" << ms.count() << RESET_COLOR << endl;
        }
    }

    static inline vector<double> read_values_from_file(const string& filename, double scale = 1) {
        vector<double> values;
        const bool profile_weights = OperationProfiler::instance().enabled() &&
                                     (filename.find("/weights/") != string::npos ||
                                      filename.rfind("../weights/", 0) == 0);
        steady_clock::time_point open_started;
        if (profile_weights) open_started = steady_clock::now();
        ifstream file(filename);
        if (profile_weights) {
            OperationProfiler::instance().recordDuration(
                "weight_file_open", "open_weight_file",
                duration<double>(steady_clock::now() - open_started).count(), filename, true);
        }

        if (!file.is_open()) {
            std::cerr << "Can not open " << filename << std::endl;
            return values; // Restituisce un vettore vuoto in caso di errore
        }

        string row;
        double read_seconds = 0.0;
        double parse_seconds = 0.0;
        while (true) {
            steady_clock::time_point read_started;
            if (profile_weights) read_started = steady_clock::now();
            const bool has_row = static_cast<bool>(std::getline(file, row));
            if (profile_weights) {
                read_seconds += duration<double>(steady_clock::now() - read_started).count();
            }
            if (!has_row) break;

            steady_clock::time_point parse_started;
            if (profile_weights) parse_started = steady_clock::now();
            istringstream stream(row);
            string value;
            while (std::getline(stream, value, ',')) {
                try {
                    double num = stod(value);
                    //num = std::floor(num * 10) / 10; //1 decimal
                    values.push_back(num * scale);
                } catch (const invalid_argument& e) {
                    cerr << "Can not convert: " << value << endl;
                }
            }
            if (profile_weights) {
                parse_seconds += duration<double>(steady_clock::now() - parse_started).count();
            }
        }
        if (profile_weights) {
            OperationProfiler::instance().recordDuration(
                "weight_file_read", "read_weight_file", read_seconds, filename);
            OperationProfiler::instance().recordDuration(
                "weight_text_parse", "parse_weight_text", parse_seconds, filename);
        }

        file.close();
        return values;
    }

    static inline vector<double> read_fc_weight (const string& filename) {
        vector<double> weight = read_values_from_file("../weights/fc.bin");
        vector<double> weight_corrected;

        constexpr int num_classes = 2;
        for (int i = 0; i < 64; i++) {
            for (int j = 0; j < num_classes; j++) {
                weight_corrected.push_back(weight[(num_classes * i) + j]);
            }
            for (int j = 0; j < 64 - num_classes; j++) {
                weight_corrected.push_back(0);
            }
        }

        return weight_corrected;
    }

    static inline vector<double> read_fc_bias(const string& filename) {
        vector<double> bias = read_values_from_file(filename);
        vector<double> bias_corrected(4096, 0.0);
        constexpr int num_classes = 2;
        for (int i = 0; i < num_classes; i++) {
            bias_corrected[i] = bias[i];
        }
        return bias_corrected;
    }

    static inline double compute_approx_error(Plaintext expected, Plaintext bootstrapped) {
        vector<complex<double>> result;
        vector<complex<double>> expectedResult;

        result = bootstrapped->GetCKKSPackedValue();
        expectedResult = expected->GetCKKSPackedValue();


        if (result.size() != expectedResult.size())
            OPENFHE_THROW(config_error, "Cannot compare vectors with different numbers of elements");

        // using the infinity norm
        double maxError = 0;
        for (size_t i = 0; i < result.size(); ++i) {
            double error = std::abs(result[i].real() - expectedResult[i].real());
            if (maxError < error)
                maxError = error;
        }

        return std::abs(std::log2(maxError));
    }

    static inline int get_relu_depth(int degree) {
        //Check: https://github.com/openfheorg/openfhe-development/blob/main/src/pke/examples/FUNCTION_EVALUATION.md
        switch (degree) {
            case 5:
                return 3;
            case 13:
                return 4;
            case 27:
                return 5;
            case 59:
                return 6;
            case 119:
                return 7;
            case 200:
            case 247:
                return 8;
            case 495:
                return 9;
            case 1007:
                return 10;
            case 2031:
                return 11;
        }

        cerr << "Set a valid degree for ReLU" << endl;
        exit(1);
    }

    static inline void write_to_file(string filename, string content) {
        ofstream file;
        file.open (filename);
        file << content.c_str();
        file.close();
    }

    static inline string read_from_file(string filename) {
        //It reads only the first line!!
        string line;
        ifstream myfile (filename);
        if (myfile.is_open()) {
            if (getline(myfile, line)) {
                myfile.close();
                return line;
            } else {
                cerr << "Could not open " << filename << "." <<endl;
                exit(1);
            }
        } else {
            cerr << "Could not open " << filename << "." <<endl;
            exit(1);
        }
    }


}

#endif //LOWMEMORYFHERESNET20_UTILS_H
