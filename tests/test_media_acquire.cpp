#include "product/media_acquire/acquire.h"

#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace {

using ninfer::product::media_acquire::Policy;
using ninfer::product::media_acquire::Source;
using ninfer::product::media_acquire::SourceKind;
using ninfer::product::media_acquire::acquire_bytes;

std::vector<std::uint8_t> decode(const std::string& encoded) {
    Source source;
    source.kind  = SourceKind::Data;
    source.value = "data:application/octet-stream;base64," + encoded;
    Policy policy;
    policy.allow_remote = false;
    policy.max_bytes    = 64;
    return acquire_bytes(source, policy);
}

void expect_decodes(const std::string& encoded, std::vector<std::uint8_t> expected) {
    if (decode(encoded) != expected) {
        throw std::runtime_error("unexpected decoded bytes for base64 fixture: " + encoded);
    }
}

void expect_rejects(const std::string& encoded) {
    try {
        (void)decode(encoded);
    } catch (const std::invalid_argument&) {
        return;
    }
    throw std::runtime_error("accepted noncanonical base64 media: " + encoded);
}

void expect_rejects_credential_url(std::string_view url) {
    Source source;
    source.kind  = SourceKind::Url;
    source.value = std::string(url);
    Policy policy;
    policy.max_bytes = 64;
    try {
        (void)acquire_bytes(source, policy);
    } catch (const std::invalid_argument& error) {
        if (std::string_view(error.what()).find("credential-free HTTP(S)") !=
            std::string_view::npos) {
            return;
        }
        throw std::runtime_error("credential-bearing media URL bypassed userinfo validation");
    }
    throw std::runtime_error("credential-bearing media URL was accepted");
}

} // namespace

int main() {
    try {
        expect_decodes("TWFu", {'M', 'a', 'n'});
        expect_decodes("TWE=", {'M', 'a'});
        expect_decodes("TQ==", {'M'});
        expect_decodes("TWE", {'M', 'a'});
        expect_decodes("TQ", {'M'});
        expect_decodes("  TQ==\r\n", {'M'});
        expect_decodes("AP8=", {0x00, 0xff});

        for (const std::string& malformed : {
                 "A", "AA=", "AAA==", "AAAA=", "A===", "AAAA===",
                 "AB==", "AAB=", "AA=A", "!!", "=AAA", "AAA=AA==",
                 "TQ===", "TWFu=", "TQ==TQ=="}) {
            expect_rejects(malformed);
        }

        expect_rejects_credential_url("https://:secret@127.0.0.1/image.png");
        expect_rejects_credential_url("http://user:secret@127.0.0.1/image.png");

        std::cout << "media acquisition base64 and URL policy conformance passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
