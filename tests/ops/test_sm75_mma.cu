#include "ops/common/mma.cuh"

#include <cuda_runtime.h>
#include <array>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <stdexcept>

namespace {
void checked(cudaError_t status) {
    if (status != cudaSuccess) { throw std::runtime_error(cudaGetErrorString(status)); }
}

// Pack the PTX operand layout from dense matrices; the CPU oracle below uses
// ordinary row/column multiplication and does not consume these fragments.
__global__ void fp16_product(const float* a, const float* b, float* out, float initial) {
    const int lane = threadIdx.x;
    const int row = lane / 4, col = 2 * (lane % 4);
    unsigned af[4], bf[2];
    for (int reg = 0; reg < 4; ++reg) {
        const int ar = row + 8 * (reg % 2), ak = col + 8 * (reg / 2);
        const half2 packed = __floats2half2_rn(a[ar * 16 + ak], a[ar * 16 + ak + 1]);
        af[reg] = *reinterpret_cast<const unsigned*>(&packed);
    }
    for (int reg = 0; reg < 2; ++reg) {
        const int bk = col + 8 * reg;
        const half2 packed = __floats2half2_rn(b[bk * 8 + row], b[(bk + 1) * 8 + row]);
        bf[reg] = *reinterpret_cast<const unsigned*>(&packed);
    }
    float c0 = initial, c1 = initial, c2 = initial, c3 = initial;
    ninfer::ops::mma_f16(c0, c1, c2, c3, af[0], af[1], af[2], af[3], bf[0], bf[1]);
    out[row * 8 + col] = c0;
    out[row * 8 + col + 1] = c1;
    out[(row + 8) * 8 + col] = c2;
    out[(row + 8) * 8 + col + 1] = c3;
}

__global__ void int8_product(const float* a, const float* b, float* out, int initial) {
    const int lane = threadIdx.x;
    const int row = lane / 4, group = lane % 4;
    unsigned af[4] = {}, bf[2] = {};
    for (int reg = 0; reg < 4; ++reg) {
        for (int element = 0; element < 4; ++element) {
            const int ar = row + 8 * (reg % 2), ak = 4 * group + element + 16 * (reg / 2);
            af[reg] |= static_cast<unsigned>(static_cast<std::uint8_t>(static_cast<std::int8_t>(a[ar * 32 + ak]))) << (8 * element);
        }
    }
    for (int reg = 0; reg < 2; ++reg) {
        for (int element = 0; element < 4; ++element) {
            const int bk = 4 * group + element + 16 * reg;
            bf[reg] |= static_cast<unsigned>(static_cast<std::uint8_t>(static_cast<std::int8_t>(b[bk * 8 + row]))) << (8 * element);
        }
    }
    int c0 = initial, c1 = initial, c2 = initial, c3 = initial;
    ninfer::ops::mma_s8(c0, c1, c2, c3, af[0], af[1], af[2], af[3], bf[0], bf[1]);
    const int col = 2 * group;
    out[row * 8 + col] = static_cast<float>(c0);
    out[row * 8 + col + 1] = static_cast<float>(c1);
    out[(row + 8) * 8 + col] = static_cast<float>(c2);
    out[(row + 8) * 8 + col + 1] = static_cast<float>(c3);
}

int run(bool integer, int initial) {
    const int k = integer ? 32 : 16;
    std::array<float, 512> a{}, b{};
    std::array<float, 128> actual{};
    for (int r = 0; r < 16; ++r) {
        for (int p = 0; p < k; ++p) { a[r * k + p] = static_cast<float>((r * 7 + p * 3) % 17 - 8) * (integer ? 1.0F : 0.25F); }
    }
    for (int p = 0; p < k; ++p) {
        for (int c = 0; c < 8; ++c) { b[p * 8 + c] = static_cast<float>((p * 5 + c * 11) % 19 - 9) * (integer ? 1.0F : 0.125F); }
    }
    float *da = nullptr, *db = nullptr, *dout = nullptr;
    checked(cudaMalloc(&da, sizeof(a)));
    checked(cudaMalloc(&db, sizeof(b)));
    checked(cudaMalloc(&dout, sizeof(actual)));
    checked(cudaMemcpy(da, a.data(), sizeof(a), cudaMemcpyHostToDevice));
    checked(cudaMemcpy(db, b.data(), sizeof(b), cudaMemcpyHostToDevice));
    if (integer) { int8_product<<<1, 32>>>(da, db, dout, initial); }
    else { fp16_product<<<1, 32>>>(da, db, dout, static_cast<float>(initial)); }
    checked(cudaGetLastError());
    checked(cudaMemcpy(actual.data(), dout, sizeof(actual), cudaMemcpyDeviceToHost));
    checked(cudaFree(da)); checked(cudaFree(db)); checked(cudaFree(dout));
    int failures = 0;
    for (int r = 0; r < 16; ++r) {
        for (int c = 0; c < 8; ++c) {
            double expected = initial;
            for (int p = 0; p < k; ++p) { expected += static_cast<double>(a[r * k + p]) * b[p * 8 + c]; }
            if (actual[r * 8 + c] != expected) {
                if (failures++ == 0) { std::cerr << (integer ? "INT8" : "FP16") << " C(" << r << ',' << c << ")=" << actual[r * 8 + c] << " expected=" << expected << '\n'; }
            }
        }
    }
    return failures;
}
}

int main() {
    int count = 0;
    if (cudaGetDeviceCount(&count) != cudaSuccess || count == 0) { return 77; }
    try {
        int failures = 0;
        for (int initial : {0, 7}) { failures += run(false, initial); failures += run(true, initial); }
        std::cout << (failures ? "FAIL" : "PASS") << " SM75 FP16/INT8 MMA dense oracle\n";
        return failures ? 1 : 0;
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
