#!/bin/bash
# lib/sanitize.sh — Shared output sanitization for step summaries.
#
# Provides wrangle_sanitize_output() which strips HTML tags and truncates
# output to prevent step summary flooding/injection.
#
# Usage: source this file, then pipe untrusted content through the function.
#   source "$SCRIPT_DIR/sanitize.sh"
#   wrangle_sanitize_output < untrusted_input

# Maximum characters for step summary (prevent flooding)
MAX_SUMMARY_LENGTH="${WRANGLE_MAX_SUMMARY:-65536}"

# Strip HTML tags from input to prevent markdown/HTML injection.
# Uses printf '%s' for untrusted content per CLAUDE.md.
wrangle_sanitize_output() {
    # Remove HTML tags, then truncate
    sed 's/<[^>]*>//g' | head -c "$MAX_SUMMARY_LENGTH"
}
