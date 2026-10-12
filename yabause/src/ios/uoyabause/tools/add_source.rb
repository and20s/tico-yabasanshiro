#!/usr/bin/env ruby
# Adds a source file to one or more Xcode targets. Idempotent: a file that is
# already a member of a target is left alone. Used instead of the Xcode GUI so
# the build can be changed from a terminal.
require "xcodeproj"

if ARGV.length < 2
  abort("usage: add_source.rb <file> <target> [<target>...]")
end

file_path = ARGV[0]
target_names = ARGV[1..]

abort("no such file: #{file_path}") unless File.exist?(file_path)

project = Xcodeproj::Project.open("YabaSnashiro.xcodeproj")

# Reuse the file reference if the project already knows this path, so the
# project navigator does not sprout a second entry for the same file.
reference = project.files.find { |f| f.real_path.to_s == File.expand_path(file_path) }
if reference.nil?
  group = project.main_group
  # Mirror the directory layout in the project navigator.
  File.dirname(file_path).split(File::SEPARATOR).each do |name|
    next if name == "."
    # Only groups the script itself creates here get their source tree
    # touched; a group that already existed is left exactly as it was.
    existing = group.find_subpath(name, false)
    group = group.find_subpath(name, true)
    group.set_source_tree("SOURCE_ROOT") if existing.nil?
  end
  reference = group.new_reference(File.expand_path(file_path))
end

target_names.each do |name|
  target = project.targets.find { |t| t.name == name }
  abort("no such target: #{name}") if target.nil?
  already = target.source_build_phase.files.any? do |build_file|
    build_file.file_ref == reference
  end
  next if already
  target.source_build_phase.add_file_reference(reference)
  puts "added #{file_path} to #{name}"
end

project.save
