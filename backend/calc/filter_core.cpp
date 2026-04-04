#include <pybind11/pybind11.h>
#include <pybind11/numpy.h>
#include <pybind11/stl.h>
#include <cmath>
#include <cstdint>
#include <vector>
#include <algorithm>
#include <numeric>

namespace py = pybind11;

// ── Portable 64-bit popcount ──

static inline int popcount64(uint64_t x) {
    x = x - ((x >> 1) & 0x5555555555555555ULL);
    x = (x & 0x3333333333333333ULL) + ((x >> 2) & 0x3333333333333333ULL);
    x = (x + (x >> 4)) & 0x0F0F0F0F0F0F0F0FULL;
    return static_cast<int>((x * 0x0101010101010101ULL) >> 56);
}

static int hamming_distance(uint64_t a, uint64_t b) {
    return popcount64(a ^ b);
}

// ═══════════════════════════════════════════════
// PHASE 0 — Early Rejection (variance + entropy)
// ═══════════════════════════════════════════════

// Returns (rejected, variance, entropy)
py::tuple phase0_check(
    py::array_t<double, py::array::c_style> pixels,
    double variance_threshold,
    double entropy_threshold
) {
    auto buf = pixels.unchecked<2>();
    const int h = buf.shape(0);
    const int w = buf.shape(1);
    const int total = h * w;

    // Mean
    double sum = 0.0;
    for (int i = 0; i < h; i++)
        for (int j = 0; j < w; j++)
            sum += buf(i, j);
    const double mean = sum / total;

    // Variance
    double var_sum = 0.0;
    for (int i = 0; i < h; i++)
        for (int j = 0; j < w; j++) {
            double d = buf(i, j) - mean;
            var_sum += d * d;
        }
    const double variance = var_sum / total;

    if (variance < variance_threshold)
        return py::make_tuple(true, variance, 0.0);

    // Histogram (256 bins, range 0-256)
    int hist[256] = {};
    for (int i = 0; i < h; i++)
        for (int j = 0; j < w; j++) {
            int bin = static_cast<int>(buf(i, j));
            if (bin < 0) bin = 0;
            if (bin > 255) bin = 255;
            hist[bin]++;
        }

    // Entropy
    double entropy = 0.0;
    for (int b = 0; b < 256; b++) {
        if (hist[b] > 0) {
            double p = static_cast<double>(hist[b]) / total;
            entropy -= p * std::log2(p);
        }
    }

    if (entropy < entropy_threshold)
        return py::make_tuple(true, variance, entropy);

    return py::make_tuple(false, variance, entropy);
}

// ═══════════════════════════════════════════════
// Pixel Feature Functions
// ═══════════════════════════════════════════════

double compute_sharpness(py::array_t<uint8_t, py::array::c_style> gray) {
    auto buf = gray.unchecked<2>();
    const int h = buf.shape(0);
    const int w = buf.shape(1);
    const int total = h * w;

    double sum = 0.0;
    double sum_sq = 0.0;

    for (int i = 1; i < h - 1; i++) {
        for (int j = 1; j < w - 1; j++) {
            double lap = static_cast<double>(buf(i - 1, j))
                       + static_cast<double>(buf(i + 1, j))
                       + static_cast<double>(buf(i, j - 1))
                       + static_cast<double>(buf(i, j + 1))
                       - 4.0 * static_cast<double>(buf(i, j));
            sum += lap;
            sum_sq += lap * lap;
        }
    }

    // Include zero-border pixels in variance (matches Python np.var)
    double mean = sum / total;
    return sum_sq / total - mean * mean;
}

double compute_noise(py::array_t<uint8_t, py::array::c_style> gray) {
    auto buf = gray.unchecked<2>();
    const int h = buf.shape(0);
    const int w = buf.shape(1);
    const int total = h * w;

    std::vector<double> abs_lap(total, 0.0);

    int idx = w; // skip first row
    for (int i = 1; i < h - 1; i++) {
        idx++; // skip first column
        for (int j = 1; j < w - 1; j++) {
            double lap = static_cast<double>(buf(i - 1, j))
                       + static_cast<double>(buf(i + 1, j))
                       + static_cast<double>(buf(i, j - 1))
                       + static_cast<double>(buf(i, j + 1))
                       - 4.0 * static_cast<double>(buf(i, j));
            abs_lap[idx] = std::abs(lap);
            idx++;
        }
        idx++; // skip last column
    }

    size_t mid = total / 2;
    std::nth_element(abs_lap.begin(), abs_lap.begin() + mid, abs_lap.end());
    return abs_lap[mid];
}

double compute_exposure_quality(py::array_t<uint8_t, py::array::c_style> gray) {
    auto buf = gray.unchecked<2>();
    const int h = buf.shape(0);
    const int w = buf.shape(1);
    const int total = h * w;

    double sum = 0.0;
    int dark = 0, bright = 0;

    for (int i = 0; i < h; i++) {
        for (int j = 0; j < w; j++) {
            uint8_t v = buf(i, j);
            sum += v;
            if (v < 5) dark++;
            if (v > 250) bright++;
        }
    }

    double mean = sum / total;
    double center_distance = std::abs(mean - 128.0) / 128.0;
    double clipped_dark = static_cast<double>(dark) / total;
    double clipped_bright = static_cast<double>(bright) / total;
    return std::max(0.0, 1.0 - center_distance - clipped_dark - clipped_bright);
}

double compute_contrast(py::array_t<uint8_t, py::array::c_style> gray) {
    auto buf = gray.unchecked<2>();
    const int h = buf.shape(0);
    const int w = buf.shape(1);
    const int total = h * w;

    double sum = 0.0;
    double sum_sq = 0.0;
    for (int i = 0; i < h; i++) {
        for (int j = 0; j < w; j++) {
            double v = static_cast<double>(buf(i, j));
            sum += v;
            sum_sq += v * v;
        }
    }
    double mean = sum / total;
    return std::sqrt(sum_sq / total - mean * mean);
}

double compute_saturation(py::array_t<uint8_t, py::array::c_style> rgb) {
    auto buf = rgb.unchecked<3>();
    const int h = buf.shape(0);
    const int w = buf.shape(1);
    const int total = h * w;

    double sat_sum = 0.0;
    for (int i = 0; i < h; i++) {
        for (int j = 0; j < w; j++) {
            double r = buf(i, j, 0);
            double g = buf(i, j, 1);
            double b = buf(i, j, 2);
            double max_c = std::max(std::max(r, g), b);
            double min_c = std::min(std::min(r, g), b);
            double denom = max_c > 0.0 ? max_c : 1.0;
            sat_sum += (max_c - min_c) / denom;
        }
    }
    return sat_sum / total;
}

// All pixel features in one call (avoids Python→C++ overhead per feature)
py::dict compute_all_pixel_features(
    py::array_t<uint8_t, py::array::c_style> gray,
    py::array_t<uint8_t, py::array::c_style> rgb
) {
    py::dict result;
    result["sharpness"] = compute_sharpness(gray);
    result["exposure_quality"] = compute_exposure_quality(gray);
    result["contrast"] = compute_contrast(gray);
    result["saturation"] = compute_saturation(rgb);
    result["noise"] = compute_noise(gray);
    return result;
}

// ═══════════════════════════════════════════════
// Visual Clustering — Union-Find + Similarity
// ═══════════════════════════════════════════════

py::array_t<int> cluster_visual_cpp(
    py::array_t<float, py::array::c_style> embeddings_arr,
    py::array_t<uint64_t, py::array::c_style> phashes_arr,
    float sim_threshold,
    int hamming_threshold,
    int knn
) {
    auto emb = embeddings_arr.unchecked<2>();
    auto ph  = phashes_arr.unchecked<1>();
    const int n   = static_cast<int>(emb.shape(0));
    const int dim = static_cast<int>(emb.shape(1));

    if (n == 0)
        return py::array_t<int>(0);

    // Compute full similarity matrix (n × n)
    std::vector<float> sim(n * n);
    for (int i = 0; i < n; i++) {
        sim[i * n + i] = 1.0f;
        for (int j = i + 1; j < n; j++) {
            float dot = 0.0f;
            for (int d = 0; d < dim; d++)
                dot += emb(i, d) * emb(j, d);
            sim[i * n + j] = dot;
            sim[j * n + i] = dot;
        }
    }

    // Union-Find
    std::vector<int> parent(n);
    std::iota(parent.begin(), parent.end(), 0);

    auto find = [&](int x) -> int {
        while (parent[x] != x) {
            parent[x] = parent[parent[x]];
            x = parent[x];
        }
        return x;
    };

    auto unite = [&](int a, int b) {
        int ra = find(a), rb = find(b);
        if (ra != rb) parent[ra] = rb;
    };

    const int k = std::min(knn, n - 1);
    if (k > 0) {
        std::vector<int> indices(n);
        for (int i = 0; i < n; i++) {
            std::iota(indices.begin(), indices.end(), 0);
            // Partition so top-k by similarity are in [n-k, n)
            std::nth_element(
                indices.begin(), indices.begin() + (n - k), indices.end(),
                [&](int a, int b) { return sim[i * n + a] < sim[i * n + b]; }
            );

            for (int t = n - k; t < n; t++) {
                int j = indices[t];
                if (j == i) continue;
                if (sim[i * n + j] > sim_threshold) {
                    unite(i, j);
                } else if (hamming_distance(ph(i), ph(j)) < hamming_threshold) {
                    unite(i, j);
                }
            }
        }
    }

    // Assign sequential labels
    auto result = py::array_t<int>(n);
    auto r = result.mutable_unchecked<1>();
    std::vector<int> root_map(n, -1);
    int next_id = 0;
    for (int i = 0; i < n; i++) {
        int root = find(i);
        if (root_map[root] == -1)
            root_map[root] = next_id++;
        r(i) = root_map[root];
    }

    return result;
}

// ═══════════════════════════════════════════════
// Module Definition
// ═══════════════════════════════════════════════

PYBIND11_MODULE(filter_core, m) {
    m.doc() = "C++ accelerated filter operations for Quemory";

    m.def("phase0_check", &phase0_check,
          "Early rejection: returns (rejected, variance, entropy)",
          py::arg("pixels"), py::arg("variance_threshold"),
          py::arg("entropy_threshold"));

    m.def("compute_sharpness", &compute_sharpness, py::arg("gray"));
    m.def("compute_noise", &compute_noise, py::arg("gray"));
    m.def("compute_exposure_quality", &compute_exposure_quality, py::arg("gray"));
    m.def("compute_contrast", &compute_contrast, py::arg("gray"));
    m.def("compute_saturation", &compute_saturation, py::arg("rgb"));
    m.def("compute_all_pixel_features", &compute_all_pixel_features,
          py::arg("gray"), py::arg("rgb"));

    m.def("cluster_visual", &cluster_visual_cpp,
          "Visual clustering with Union-Find on cosine similarity + pHash",
          py::arg("embeddings"), py::arg("phashes"),
          py::arg("sim_threshold"), py::arg("hamming_threshold"),
          py::arg("knn"));
}
