#!/bin/bash
# Regenerates hue.xcodeproj from project.yml and re-applies the Resources
# build phase patch (see patch_resources.rb — xcodegen 2.46.0 doesn't emit
# one for this machine's Xcode 26 project format). Run this any time you add
# a new source file or resource, instead of calling `xcodegen generate` alone.
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate
GEM_HOME=/Users/kelyon/.gem/ruby/2.6.0 GEM_PATH=/Users/kelyon/.gem/ruby/2.6.0 \
  ruby -I/Users/kelyon/.gem/ruby/2.6.0/gems/xcodeproj-1.28.1/lib patch_resources.rb
