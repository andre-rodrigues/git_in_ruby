#!/usr/bin/env ruby

# To make sure all objects are "loose":
#
# 1) Move all pack files to a temp folder
# 2) For each pack file (.pack extensions), run: git unpack-objects < <pack>

require 'digest/sha1'
require 'zlib'
require 'fileutils'

require File.join(File.dirname(File.expand_path(__FILE__)), 'memoize')
require File.join(File.dirname(File.expand_path(__FILE__)), 'sha1_util')
require File.join(File.dirname(File.expand_path(__FILE__)), 'string_extensions')

# List of possible exceptions.
class InvalidModeError          < StandardError; end
class InvalidSha1Error          < StandardError; end
class InvalidSizeError          < StandardError; end
class InvalidTypeError          < StandardError; end
class MissingObjectError        < StandardError; end
class ExcessiveCommitDataError  < StandardError; end
class MissingCommitDataError    < StandardError; end

class GitRepository
  extend Memoize

  attr_reader :bare_repository, :objects

  def initialize(options = {})
    options = {
      bare_repository: false
    }.merge(options)

    @objects         = {}
    @bare_repository = options[:bare_repository]
  end

  def head_commit
    Commit.find_or_initialize_by_sha1 self, head_commit_sha1
  end

  def head_fsck!
    head_commit.validate
  end

  def head_commit_sha1
    raise NotImplementedError
  end

  def load_object(sha1)
    raise NotImplementedError
  end

  def parse_object(raw_content)
    raise NotImplementedError
  end

  remember :head_commit_sha1
end

class FileSystemGitRepository < GitRepository
  attr_reader :project_path

  def initialize(options = {})
    super

    @project_path = options[:project_path]
  end

  def git_path
    bare_repository ? project_path : File.join(project_path, '.git')
  end

  def head_commit_sha1
    head_ref_path = File.read(File.join(git_path, 'HEAD')).chomp[/\Aref: (.*)/, 1]

    File.read(File.join(git_path, head_ref_path)).chomp
  end

  def parse_object(raw_content)
    first_null_byte_index = raw_content.index("\0")
    header                = raw_content[0...first_null_byte_index]
    type, size            = header =~ /(\w+) (\d+)/ && [$1.to_sym, $2.to_i]
    data                  = raw_content[first_null_byte_index+1..-1]

    { type: type, size: size, data: data }
  end

  def load_object(sha1)
    path = File.join(git_path, 'objects', sha1[0, 2], sha1[2..-1])

    raise MissingObjectError, "File '#{path}' not found! Have you unpacked all pack files?" unless File.exists?(path)

    raw_content = Zlib::Inflate.inflate File.read(path)

    parse_object(raw_content).merge content_sha1: Digest::SHA1.hexdigest(raw_content)
  end
end

class GitObject
  extend Memoize

  attr_reader :repository, :sha1, :commit_level, :type, :size, :data, :content_sha1

  # http://stackoverflow.com/questions/737673/how-to-read-the-mode-field-of-git-ls-trees-output
  VALID_MODES = {
    '40000'  => 'Tree',
    '100644' => 'Blob',
    '100755' => 'ExecutableFile',
    '100664' => 'GroupWriteableFile',
    '120000' => 'SymLink',
    '160000' => 'GitSubModule'
  }

  def self.find_or_initialize_by_sha1(repository, sha1, commit_level = 1)
    repository.objects[sha1] ||= new(repository, Sha1Util.standardized_sha1(sha1), commit_level)
  end

  def initialize(repository, sha1, commit_level)
    @repository   = repository
    @sha1         = sha1
    @commit_level = commit_level

    load
  end

  def validate
    puts "(#{commit_level}) Validating #{self.class.name} with SHA1 #{sha1} "

    # Locate the ancestor class which is the immediate subclass of GitObject in the hierarchy chain (one of: Blob, Commit or Tree).
    expected_type = (self.class.ancestors.find { |cls| cls.superclass == GitObject }).name.underscore.to_sym

    raise InvalidTypeError, "Invalid type '#{type}' (expected '#{expected_type}')"  unless type == expected_type
    raise InvalidSizeError, "Invalid size #{size} (expected #{data.size})"          unless size == data.size
    raise InvalidSha1Error, "Invalid SHA1 '#{sha1}' (expected '#{content_sha1}')"   unless sha1 == content_sha1

    validate_data
  end

  def validate_data
    raise NotImplementedError
  end

  private

  def load
    object_info = repository.load_object(@sha1)

    @content_sha1 = object_info[:content_sha1]
    @type         = object_info[:type]
    @size         = object_info[:size]
    @data         = object_info[:data]
  end
end

class Commit < GitObject
  attr_reader :tree, :author, :date, :subject

  def initialize(repository, sha1, commit_level)
    super

    @tree          = Tree.find_or_initialize_by_sha1(@repository, read_row('tree'), @commit_level)
    @author, @date = read_row('author') =~ /(.*) (\d+) [+-]\d{4}/ && [$1, Time.at($2.to_i)]
    @subject       = read_subject
  end

  def parents
    read_rows('parent').map { |sha1| Commit.find_or_initialize_by_sha1(@repository, sha1, @commit_level + 1) }
  end

  def parent
    if parents.size == 1
      parents[0]
    else
      raise "Zero or more than one parent commit found."
    end
  end

  def validate_data
    tree.validate
    parents.each &:validate
  end

  def checkout!(destination_path = File.join('checkout_files', sha1[0..6]))
    FileUtils.mkpath destination_path

    tree.checkout! destination_path
  end

  def interesting_changes_introduced_by
    updates_and_creations = tree.interesting_changes_between(parents.map(&:tree))

    # Find deletions between the current commit and its parents by finding the *common* additions the other way around, i.e.
    # between each of the parents and the current commit, then transforming them into deletions.
    deletions = parents.map { |parent|
      parent.tree.interesting_changes_between([tree]).find_all { |(_, action, _)| action == :created }.map { |name, _, sha1s| [name, :deleted, sha1s.reverse] }
    }.inject(:&) || []
    updates_and_creations.concat deletions

    # Identify renamed files, replacing the :created and :deleted associated pair by a single :renamed one.
    updates_and_creations.find_all { |(_, action, _)| action == :created }.inject(updates_and_creations) { |changes, created_file|
      if (deleted_file = changes.find { |(_, action, (deleted_sha1, _))| action == :deleted && deleted_sha1 == created_file[2][1] })
        changes.delete created_file
        changes.delete deleted_file
        changes << ["#{deleted_file[0]} -> #{created_file[0]}", :renamed, [deleted_file[2][0], created_file[2][1]]]
      end

      changes
    }
  end

  private

  def read_row(label)
    rows = read_rows(label)

    if rows.size == 0
      raise MissingCommitDataError, "Missing #{label} in commit."
    elsif rows.size > 1
      raise ExcessiveCommitDataError, "Excessive #{label} rows in commit."
    end

    rows[0]
  end

  def read_rows(label)
    rows = @data.split("\n")

    rows.find_all { |row| row.split[0] == label }.map { |row| row[/\A\w+ (.*)/, 1] }
  end

  def read_subject
    rows = @data.split("\n")

    if !(empty_row_index = rows.index(''))
      raise MissingCommitDataError, "Missing subject in commit."
    end

    rows[empty_row_index+1..-1].join("\n")
  end

  remember :parents, :validate
end

class Tree < GitObject
  attr_reader :entries

  def initialize(repository, sha1, commit_level)
    super

    @entries = read_entries
  end

  def validate_data
    entries.values.each &:validate
  end

  def checkout!(destination_path = nil)
    entries.each do |name, entry|
      filename_or_path = destination_path ? File.join(destination_path, name) : name

      puts "Checking out #{filename_or_path}"

      case entry
        when ExecutableFile, GroupWriteableFile, Blob then
          filemode =
            case entry
              when ExecutableFile     then  0755
              when GroupWriteableFile then  0664
              else                          0644    # Blob
            end

          File.write filename_or_path, entry.data
          File.chmod filemode, filename_or_path
        when Tree then
          puts "Creating folder #{filename_or_path}"

          FileUtils.mkpath filename_or_path
          entry.checkout! filename_or_path
        else
          puts "Skipping #{filename_or_path}..."
      end
    end
  end

  def interesting_changes_between(other_trees, base_path = nil)
    entries.inject([]) do |changes, (name, entry)|
      filename_or_path = base_path ? File.join(base_path, name) : name

      if [Tree, Blob, ExecutableFile, GroupWriteableFile].include?(entry.class)
        other_entries = other_trees.map { |tree| tree.entries[name] }.compact

        # For merge rules, check: http://thomasrast.ch/git/evil_merge.html
        if other_entries.empty?
          action = :created
          sha1s  = [[], entry.sha1[0..6]]
        elsif !other_entries.map(&:sha1).include?(entry.sha1)
          action = :updated
          sha1s  = [other_entries.map { |e| e.sha1[0..6] }.compact.uniq, entry.sha1[0..6]]
        end

        if action   # A nil action indicates an unchanged file.
          if Tree === entry
            changes.concat entry.interesting_changes_between(other_entries.find_all { |e| Tree === e }, filename_or_path)
          else    # Blob or one of its subclasses.
            changes << [filename_or_path, action, sha1s]
          end
        end
      else
        puts "Skipping #{filename_or_path}..."
      end

      changes
    end
  end

  private

  def read_entries
    @data.scan(/(\d+) ([^\0]+)\0([\x00-\xFF]{20})/).inject({}) do |entries, (mode, name, sha1)|
      raise InvalidModeError, "Invalid mode #{mode} in file '#{name}'" unless VALID_MODES[mode]

      # Instantiate the object, based on its mode (Blob, Tree, ExecutableFile etc).
      entries.merge name => Object.const_get(VALID_MODES[mode]).find_or_initialize_by_sha1(@repository, sha1, @commit_level)
    end
  end

  remember :validate
end

class Blob < GitObject
  def validate_data
  end

  remember :validate
end

class ExecutableFile < Blob
end

class GroupWriteableFile < Blob
end

class SymLink < Blob
end

class GitSubModule < Blob
  def load
  end

  def validate
  end
end

def run!(project_path)
  repository = FileSystemGitRepository.new(project_path: project_path)
  repository.head_fsck!
end

run! ARGV[0] || '.' if __FILE__ == $0
