#include <ninfer/targets/qwen3_6/decoder_state.h>

#include "core/dtype.h"
#include "core/layout.h"

#include <cstddef>
#include <cstdint>
#include <iostream>
#include <stdexcept>

namespace {

using ninfer::DType;
using ninfer::LayoutBuilder;
using ninfer::targets::qwen3_6::DecoderStateLayout;
using ninfer::targets::qwen3_6::DecoderStateSpec;
using ninfer::targets::qwen3_6::kKvQuantGroup;

int fail(const char* message) {
    std::cerr << message << '\n';
    return 1;
}

DecoderStateLayout plan(DType dtype, bool packed_v = false, bool rotate_k = false,
                        bool rotate_v = false, bool packed_k = false, bool e8_lattice = false) {
    LayoutBuilder builder;
    return ninfer::targets::qwen3_6::plan_decoder_state(
        builder, DecoderStateSpec{
                     .full_attention_layers = 1,
                     .mtp_layers            = 0,
                     .capacity              = 128,
                     .kv_heads              = 4,
                     .attention_head_dim    = 128,
                     .kv_dtype              = dtype,
                     .kv_quant_group        = dtype == DType::BF16 ? 0 : kKvQuantGroup,
                     .kv_packed_v           = packed_v,
                     .kv_rotate_k           = rotate_k,
                     .kv_rotate_v           = rotate_v,
                     .kv_packed_k           = packed_k,
                     .kv_e8_lattice         = e8_lattice,
                     .enable_mtp            = false,
                     .kv_table_rows         = 1,
                     .text_physical_page_groups = 2,
                     .mtp_physical_page_groups  = 0,
                     .linear_attention =
                         {
                             .layers         = 1,
                             .conv_channels  = 64,
                             .conv_width     = 4,
                             .value_heads    = 2,
                             .value_head_dim = 16,
                             .key_head_dim   = 16,
                             .slot_count     = 1,
                             .conv_dtype     = DType::BF16,
                         },
                 });
}

int check_plain_int8() {
    const auto layout = plan(DType::I8);
    const auto& kv = layout.text_kv;
    int failures = 0;
    if (kv.pool.planes.size() != 4) { return fail("INT8 cache must have four planes"); }
    if (kv.pool.planes[0].spec.dtype != DType::I8 || kv.pool.planes[0].spec.leading_extent != 128 ||
        kv.pool.planes[1].spec.dtype != DType::I8 || kv.pool.planes[1].spec.leading_extent != 128) {
        failures += fail("INT8 K/V planes have unexpected geometry");
    }
    if (kv.pool.planes[2].spec.dtype != DType::FP16 || kv.pool.planes[2].spec.leading_extent != 2 ||
        kv.pool.planes[3].spec.dtype != DType::FP16 || kv.pool.planes[3].spec.leading_extent != 2) {
        failures += fail("INT8 scale planes have unexpected geometry");
    }
    if (kv.packed_k || kv.packed_v || kv.rotate_k || kv.rotate_v || kv.e8_lattice) {
        failures += fail("plain INT8 cache unexpectedly advertises RK flags");
    }
    return failures;
}

int check_rk4v4_e8() {
    const auto int8 = plan(DType::I8);
    const auto rk = plan(DType::I8, true, true, true, true, true);
    const auto& kv = rk.text_kv;
    int failures = 0;

    if (kv.pool.planes.size() != 4) { return fail("RK4V4E8 cache must have four planes"); }
    if (kv.pool.planes[0].spec.dtype != DType::U8 || kv.pool.planes[0].spec.leading_extent != 64 ||
        kv.pool.planes[1].spec.dtype != DType::U8 || kv.pool.planes[1].spec.leading_extent != 64) {
        failures += fail("RK4V4E8 K/V planes are not nibble-packed");
    }
    if (kv.pool.planes[2].spec.dtype != DType::FP16 || kv.pool.planes[2].spec.leading_extent != 2 ||
        kv.pool.planes[3].spec.dtype != DType::FP16 || kv.pool.planes[3].spec.leading_extent != 2) {
        failures += fail("RK4V4E8 scale planes changed unexpectedly");
    }
    if (!kv.packed_k || !kv.packed_v || !kv.rotate_k || !kv.rotate_v || !kv.e8_lattice) {
        failures += fail("RK4V4E8 layout metadata is incomplete");
    }
    if (!(rk.kv_payload_bytes() < int8.kv_payload_bytes())) {
        failures += fail("RK4V4E8 layout did not reduce KV payload bytes");
    }

    // Exact payload check for this geometry: 2 physical page groups, 64 tokens/page,
    // 4 heads, K/V at 64 packed bytes per token/head, plus two FP16 scale planes
    // with two groups per token/head.
    constexpr std::size_t expected_data =
        2ULL * 2ULL * 64ULL * 64ULL * 4ULL; // K+V, page groups, page tokens, packed extent, heads
    constexpr std::size_t expected_scales =
        2ULL * 2ULL * 64ULL * 2ULL * 4ULL * sizeof(std::uint16_t);
    const std::size_t expected = expected_data + expected_scales;
    if (rk.text_kv.payload_bytes() != expected) {
        std::cerr << "RK4V4E8 payload expected " << expected << ", got "
                  << rk.text_kv.payload_bytes() << '\n';
        ++failures;
    }
    return failures;
}

int check_invalid_combinations() {
    int failures = 0;
    try {
        (void)plan(DType::BF16, true, true, true, true, true);
        failures += fail("packed BF16 cache was accepted");
    } catch (const std::invalid_argument&) {}

    try {
        (void)plan(DType::I8, false, false, true, false, false);
        failures += fail("rotate_v without packed_v was accepted");
    } catch (const std::invalid_argument&) {}

    try {
        (void)plan(DType::I8, true, true, true, false, true);
        failures += fail("E8 lattice without packed_k was accepted");
    } catch (const std::invalid_argument&) {}
    return failures;
}

} // namespace

int main() {
    int failures = 0;
    failures += check_plain_int8();
    failures += check_rk4v4_e8();
    failures += check_invalid_combinations();
    return failures == 0 ? 0 : 1;
}
