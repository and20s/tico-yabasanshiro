#!/usr/bin/env ruby
# Adds source files to the YabaSnashiro Xcode project.
# Usage: bundle exec ruby tools/add_files_to_project.rb <app|tests> <file> [<file>...]
# Files are added to the group hierarchy mirroring their directory path
# and registered in the compile sources phase of the chosen target.
require 'xcodeproj'
require 'pathname'

proj_path = File.expand_path('../YabaSnashiro.xcodeproj', __dir__)
project = Xcodeproj::Project.open(proj_path)

kind = ARGV.shift
candidates = case kind
             when 'tests' then [%w[uoyabauseTests YabaSnashiroTests]]
             # Sources belong to both apps: registering only the full target
             # leaves the Lite build unable to compile the new file.
             when 'app' then [%w[uoyabause YabaSnashiro], ['YabaSnashiro-Lite']]
             else abort "usage: #{$PROGRAM_NAME} <app|tests> <file> [<file>...]"
             end

targets = candidates.map do |names|
  project.targets.find { |t| names.include?(t.name) } ||
    abort("target not found: #{names.join(' / ')}. available: #{project.targets.map(&:name).join(', ')}")
end

project_dir = Pathname.new(File.dirname(proj_path))
ARGV.each do |path|
  abs = Pathname.new(File.expand_path(path))
  rel = abs.relative_path_from(project_dir)
  group = project.main_group
  rel.dirname.each_filename do |dir|
    next if dir == '.'
    group = group[dir] || group.new_group(dir, dir)
  end
  file_ref = group.files.find { |f| f.display_name == abs.basename.to_s } || group.new_file(abs.to_s)
  targets.each do |target|
    if target.source_build_phase.files_references.include?(file_ref)
      puts "already in #{target.name}: #{rel}"
    else
      target.add_file_references([file_ref])
      puts "added #{rel} -> #{target.name}"
    end
  end
end
project.save
