#pragma once

#include <string>

namespace go_mapi {

struct CounterpartRequirement {
    std::string component;
    std::string minInclusive;
    std::string maxExclusive;
};

enum class CompatibilityStatus { Compatible, Missing, Invalid, BelowMinimum, AboveMaximum };

struct CompatibilityResult {
    CompatibilityStatus status{CompatibilityStatus::Invalid};
    std::string installedVersion;
    CounterpartRequirement required;
    std::string action;
};

CompatibilityResult EvaluateCompatibility(const std::string& installed,
                                          const CounterpartRequirement& required,
                                          const std::string& action);
const char* CompatibilityStatusName(CompatibilityStatus status);
bool IsStrictReleaseVersion(const std::string& value);

} // namespace go_mapi
