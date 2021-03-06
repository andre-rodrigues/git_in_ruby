class MemoryGitRepository < GitRepository
  attr_reader :branches, :head, :objects

  def initialize(options = {})
    super

    @branches = {}
    @head     = 'master'
    @objects  = {}
  end

  def head_commit_sha1
    branches[head]
  end

  def parse_object(raw_content)
    { type: raw_content[0], size: raw_content[1], data: raw_content[2] }
  end

  def format_commit_data(tree_sha1, parents_sha1, author, committer, subject)
    [tree_sha1, parents_sha1, author, committer, subject]
  end

  def parse_commit_data(data)
    {
      tree_sha1:    data[0],
      parents_sha1: data[1],
      author:       data[2],
      committer:    data[3],
      subject:      data[4]
    }
  end

  def format_tree_data(entries)
    entries.map { |entry| [GitObject.mode_for_type(entry[0]), entry[1], entry[2]] }
  end

  def parse_tree_data(data)
    { entries_info: data }
  end

  def load_object(sha1)
    raise MissingObjectError, "Object not found!" unless objects[sha1]

    raw_content = objects[sha1]

    parse_object(raw_content).merge content_sha1: sha1_from_raw_content(raw_content)
  end

  def create_git_object!(type, data)
    raw_content = [type, data.size, data]
    sha1        = sha1_from_raw_content(raw_content)

    objects[sha1] ||= raw_content

    sha1
  end

  def update_branch!(name, commit_sha1)
    branches[name] = commit_sha1
  end

  def branch_names
    branches.keys
  end

  private

  def sha1_from_raw_content(raw_content)
    Digest::SHA1.hexdigest raw_content.map(&:to_s).join("\n")
  end
end