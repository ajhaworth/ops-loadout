#!/usr/bin/env bash
# macos/defaults/keyboard.sh - Keyboard preferences

apply_keyboard() {
    defaults_set NSGlobalDomain KeyRepeat int 2 "Set a fast keyboard repeat rate"
    defaults_set NSGlobalDomain InitialKeyRepeat int 15 "Set a short delay until repeat"
    defaults_set NSGlobalDomain NSAutomaticCapitalizationEnabled bool false "Disable automatic capitalization"
    defaults_set NSGlobalDomain NSAutomaticDashSubstitutionEnabled bool false "Disable smart dashes"
    defaults_set NSGlobalDomain NSAutomaticPeriodSubstitutionEnabled bool false "Disable automatic period substitution"
    defaults_set NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled bool false "Disable smart quotes"
    defaults_set NSGlobalDomain NSAutomaticSpellingCorrectionEnabled bool false "Disable auto-correct"

    # Enable Japanese input (Kotoeri with Romaji typing) if configured. This
    # writes an -array of dicts, which doesn't fit defaults_set's scalar
    # bool|int|float|string shape, so it's a hook instead.
    if [[ "${PROFILE_JAPANESE_INPUT:-false}" == "true" ]]; then
        local japanese_apply_cmd
        japanese_apply_cmd=$(cat <<'CMD'
defaults write com.apple.HIToolbox AppleEnabledInputSources -array \
    '<dict><key>InputSourceKind</key><string>Keyboard Layout</string><key>KeyboardLayout ID</key><integer>0</integer><key>KeyboardLayout Name</key><string>U.S.</string></dict>' \
    '<dict><key>Bundle ID</key><string>com.apple.inputmethod.Kotoeri.RomajiTyping</string><key>InputSourceKind</key><string>Keyboard Input Method</string></dict>' \
    '<dict><key>Bundle ID</key><string>com.apple.inputmethod.Kotoeri.RomajiTyping</string><key>Input Mode</key><string>com.apple.inputmethod.Japanese</string><key>InputSourceKind</key><string>Input Mode</string></dict>'
CMD
)
        defaults_hook "japanese-input" "Enable Japanese input (Kotoeri with Romaji typing)" \
            'defaults read com.apple.HIToolbox AppleEnabledInputSources 2>/dev/null | grep -q Kotoeri' \
            "$japanese_apply_cmd"
    fi
}
