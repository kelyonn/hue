#!/usr/bin/env ruby
# Patches the xcodegen-generated hue.xcodeproj to add a Resources build phase
# with Assets.xcassets and Fonts as folder references.
#
# Why this exists: xcodegen 2.46.0 (the latest available via Homebrew) does
# not emit a PBXResourcesBuildPhase at all when generating for this
# machine's Xcode 26 / objectVersion 77 project format — verified reproducible
# even in a minimal from-scratch xcodegen project, so it's a real tool/Xcode
# version incompatibility, not a project.yml mistake. `resources:` in
# project.yml is left in place (documents intent, costs nothing), but actually
# getting Assets.xcassets/Fonts into the built app bundle requires this
# post-processing patch after every `xcodegen generate`.
require 'xcodeproj'

project_path = 'hue.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.native_targets.find { |t| t.name == 'hue' }
raise "target 'hue' not found" unless target

main_group = project.main_group.find_subpath('hue', true)

def ensure_reference(group, path, file_type)
  existing = group.children.find { |c| c.path == path }
  return existing if existing
  ref = group.new_reference(path)
  ref.last_known_file_type = file_type
  ref.name = path
  ref
end

assets_ref = ensure_reference(main_group, 'Assets.xcassets', 'folder.assetcatalog')
fonts_ref  = ensure_reference(main_group, 'Fonts', 'folder')

resources_phase = target.resources_build_phase # auto-creates if missing

[assets_ref, fonts_ref].each do |ref|
  already = resources_phase.files.any? { |bf| bf.file_ref == ref }
  resources_phase.add_file_reference(ref) unless already
end

project.save
puts "Patched #{project_path}: Resources phase has #{resources_phase.files.count} file(s)."
