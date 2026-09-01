#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include "doctest.h"
#include "component_compat.h"

#include <fstream>
#include <regex>
#include <sstream>

using namespace go_mapi;

static std::string field(const std::string& object, const char* name) {
    const std::regex pattern(std::string("\\\"") + name + "\\\"\\s*:\\s*\\\"([^\\\"]*)\\\"");
    std::smatch match;
    return std::regex_search(object, match, pattern) ? match[1].str() : "";
}

TEST_CASE("C++ compatibility decisions match the shared fixture matrix") {
    std::ifstream input(GO_MAPI_COMPAT_FIXTURE);
    REQUIRE(input.good());
    std::stringstream buffer;
    buffer << input.rdbuf();
    const std::string json = buffer.str();
    const std::regex objectPattern(R"(\{[^{}]+\})");
    size_t cases = 0;
    for (std::sregex_iterator it(json.begin(), json.end(), objectPattern), end; it != end; ++it) {
        const std::string object = it->str();
        const std::string name = field(object, "name");
        if (name.empty()) continue;
        CounterpartRequirement requirement{"app", field(object, "minInclusive"), field(object, "maxExclusive")};
        const auto result = EvaluateCompatibility(field(object, "installed"), requirement, "update-app");
        INFO("fixture: " << name);
        CHECK(std::string(CompatibilityStatusName(result.status)) == field(object, "status"));
        ++cases;
    }
    CHECK(cases >= 12);
}

TEST_CASE("development and non-canonical versions are not release versions") {
    CHECK(IsStrictReleaseVersion("4.0.0"));
    CHECK(IsStrictReleaseVersion("4.0.0-rc.2+build.1"));
    CHECK_FALSE(IsStrictReleaseVersion("0.0.0-dev"));
    CHECK_FALSE(IsStrictReleaseVersion("v4.0.0"));
    CHECK_FALSE(IsStrictReleaseVersion("4.0"));
}
