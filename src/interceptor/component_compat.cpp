#include "component_compat.h"

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <limits>
#include <sstream>
#include <vector>

namespace go_mapi {
namespace {

struct Version {
    uint64_t major{}, minor{}, patch{};
    std::vector<std::string> prerelease;
};

std::vector<std::string> Split(const std::string& value, char delimiter) {
    std::vector<std::string> result;
    std::stringstream stream(value);
    std::string item;
    while (std::getline(stream, item, delimiter)) result.push_back(item);
    if (!value.empty() && value.back() == delimiter) result.emplace_back();
    return result;
}

bool IsNumeric(const std::string& value) {
    if (value.empty() || (value.size() > 1 && value[0] == '0')) return false;
    return std::all_of(value.begin(), value.end(), [](unsigned char ch) { return std::isdigit(ch) != 0; });
}

bool ValidIdentifiers(const std::string& value, bool prerelease) {
    if (value.empty()) return false;
    for (const auto& id : Split(value, '.')) {
        if (id.empty()) return false;
        const bool numeric = std::all_of(id.begin(), id.end(), [](unsigned char ch) { return std::isdigit(ch) != 0; });
        if (prerelease && numeric && id.size() > 1 && id[0] == '0') return false;
        for (unsigned char ch : id) {
            if (!(std::isalnum(ch) || ch == '-')) return false;
        }
    }
    return true;
}

bool ParseNumber(const std::string& value, uint64_t& output) {
    if (!IsNumeric(value)) return false;
    try {
        size_t consumed = 0;
        output = std::stoull(value, &consumed, 10);
        return consumed == value.size();
    } catch (...) { return false; }
}

bool ParseVersion(const std::string& input, Version& output) {
    if (input.empty() || input[0] == 'v' || std::any_of(input.begin(), input.end(), [](unsigned char ch) { return std::isspace(ch) != 0; })) return false;
    std::string value = input;
    const auto plus = value.find('+');
    if (plus != std::string::npos) {
        if (value.find('+', plus + 1) != std::string::npos || !ValidIdentifiers(value.substr(plus + 1), false)) return false;
        value.resize(plus);
    }
    const auto dash = value.find('-');
    std::string core = value;
    if (dash != std::string::npos) {
        const std::string pre = value.substr(dash + 1);
        if (!ValidIdentifiers(pre, true)) return false;
        output.prerelease = Split(pre, '.');
        core.resize(dash);
    }
    const auto parts = Split(core, '.');
    return parts.size() == 3 && ParseNumber(parts[0], output.major) &&
           ParseNumber(parts[1], output.minor) && ParseNumber(parts[2], output.patch);
}

int Compare(const Version& left, const Version& right) {
    const uint64_t a[] = {left.major, left.minor, left.patch};
    const uint64_t b[] = {right.major, right.minor, right.patch};
    for (int i = 0; i < 3; ++i) {
        if (a[i] < b[i]) return -1;
        if (a[i] > b[i]) return 1;
    }
    if (left.prerelease.empty() && right.prerelease.empty()) return 0;
    if (left.prerelease.empty()) return 1;
    if (right.prerelease.empty()) return -1;
    const size_t count = (std::min)(left.prerelease.size(), right.prerelease.size());
    for (size_t i = 0; i < count; ++i) {
        const std::string& l = left.prerelease[i];
        const std::string& r = right.prerelease[i];
        const bool ln = std::all_of(l.begin(), l.end(), [](unsigned char ch) { return std::isdigit(ch) != 0; });
        const bool rn = std::all_of(r.begin(), r.end(), [](unsigned char ch) { return std::isdigit(ch) != 0; });
        if (ln && rn) {
            const uint64_t lv = std::stoull(l), rv = std::stoull(r);
            if (lv < rv) return -1;
            if (lv > rv) return 1;
        } else if (ln != rn) {
            return ln ? -1 : 1;
        } else if (l != r) {
            return l < r ? -1 : 1;
        }
    }
    if (left.prerelease.size() < right.prerelease.size()) return -1;
    if (left.prerelease.size() > right.prerelease.size()) return 1;
    return 0;
}

} // namespace

CompatibilityResult EvaluateCompatibility(const std::string& installed,
                                          const CounterpartRequirement& required,
                                          const std::string& action) {
    CompatibilityResult result;
    result.installedVersion = installed;
    result.required = required;
    result.action = action;
    if (installed.empty()) { result.status = CompatibilityStatus::Missing; return result; }
    Version got, minimum, maximum;
    if (required.component.empty() || !ParseVersion(installed, got) || !ParseVersion(required.minInclusive, minimum)) {
        result.status = CompatibilityStatus::Invalid; return result;
    }
    const bool hasMaximum = !required.maxExclusive.empty();
    if (hasMaximum && (!ParseVersion(required.maxExclusive, maximum) || Compare(maximum, minimum) <= 0)) {
        result.status = CompatibilityStatus::Invalid; return result;
    }
    if (Compare(got, minimum) < 0) { result.status = CompatibilityStatus::BelowMinimum; return result; }
    if (hasMaximum && Compare(got, maximum) >= 0) { result.status = CompatibilityStatus::AboveMaximum; return result; }
    result.status = CompatibilityStatus::Compatible;
    return result;
}

const char* CompatibilityStatusName(CompatibilityStatus status) {
    switch (status) {
    case CompatibilityStatus::Compatible: return "compatible";
    case CompatibilityStatus::Missing: return "missing";
    case CompatibilityStatus::Invalid: return "invalid";
    case CompatibilityStatus::BelowMinimum: return "below-minimum";
    case CompatibilityStatus::AboveMaximum: return "above-maximum";
    }
    return "invalid";
}

bool IsStrictReleaseVersion(const std::string& value) {
    Version parsed;
    return value != "0.0.0-dev" && ParseVersion(value, parsed);
}

} // namespace go_mapi
