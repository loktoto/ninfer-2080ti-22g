#pragma once

#include "artifact/reader.h"

#include <cstddef>
#include <cstdint>
#include <initializer_list>
#include <string>
#include <string_view>
#include <utility>

namespace ninfer::targets::qwen3_6_27b::detail {

inline constexpr std::size_t kDFlash2StubLayers          = 5;
inline constexpr std::size_t kDFlash2StubTensorsPerLayer = 12;
inline constexpr std::size_t kDFlash2StubFixedTensors    = 6;
inline constexpr std::size_t kDFlash2StubObjectCount =
    kDFlash2StubLayers * kDFlash2StubTensorsPerLayer + kDFlash2StubFixedTensors;

static_assert(kDFlash2StubObjectCount == 66);

template <class Visitor>
void for_each_dflash2_stub_tensor(Visitor&& visitor) {
    using artifact::NumericFormat;

    const auto visit = [&](std::string_view name, NumericFormat format,
                           std::initializer_list<std::uint64_t> shape) {
        std::forward<Visitor>(visitor)(name, format, shape);
    };

    visit("dflash2/feature_projection", NumericFormat::W8G32_F16S, {5120, 25600});
    visit("dflash2/context_norm", NumericFormat::BF16, {5120});

    for (std::size_t layer = 0; layer < kDFlash2StubLayers; ++layer) {
        const std::string prefix = "dflash2/layers/" + std::to_string(layer) + "/";
        visit(prefix + "input_norm", NumericFormat::BF16, {5120});
        visit(prefix + "attention_conv/base_kernel", NumericFormat::BF16, {2, 2, 5120});
        visit(prefix + "attention_conv/kernel_projection", NumericFormat::BF16, {1280, 5120});
        visit(prefix + "attention/query_key_value", NumericFormat::W8G32_F16S, {6144, 5120});
        visit(prefix + "attention/query_norm", NumericFormat::BF16, {128});
        visit(prefix + "attention/key_norm", NumericFormat::BF16, {128});
        visit(prefix + "attention/output", NumericFormat::W8G32_F16S, {5120, 4096});
        visit(prefix + "post_attention_norm", NumericFormat::BF16, {5120});
        visit(prefix + "mlp_conv/base_kernel", NumericFormat::BF16, {2, 2, 5120});
        visit(prefix + "mlp_conv/kernel_projection", NumericFormat::BF16, {1280, 5120});
        visit(prefix + "mlp/gate_up", NumericFormat::W8G32_F16S, {34816, 5120});
        visit(prefix + "mlp/down", NumericFormat::W8G32_F16S, {5120, 17408});
    }

    visit("dflash2/final_norm", NumericFormat::BF16, {5120});
    visit("dflash2/candidate_selector/hidden_projection", NumericFormat::BF16, {256, 5120});
    visit("dflash2/candidate_selector/predecessor_codebook", NumericFormat::BF16, {248320, 256});
    visit("dflash2/candidate_selector/successor_codebook", NumericFormat::BF16, {248320, 256});
}

} // namespace ninfer::targets::qwen3_6_27b::detail
