#!/usr/bin/env ruby

require 'json'
require 'logger'
require 'octokit'
require 'optparse'
require 'sequel'
require 'yaml'

class Migrator
  def initialize(trac, github, users, labels)
    @trac = trac
    @gh = github
    # Only collaborators are viable assignees.
    collaborators = @gh.collaborators.map { |c| c[:login] }
    @users = Hash[users.select { |from,to| collaborators.include?(to) }]
    @labels = Hash[labels.map { |topic, rx| [topic, rx.map { |f, t| [Regexp.new(f), t] }] }]
    @milestones = {}
    @issues = {}
  end

  def migrate
    migrate_milestones
    migrate_tickets
    replay_changes
  end

  private

  def migrate_milestones
    $logger.info('migrating milestones')
    ghm = Hash[@gh.list_milestones.map { |m| [m[:title], m] }]
    @trac.milestones.each do |m|
      title = m[:name]
      if ghm.has_key?(title)
        $logger.warn("skipping already existing milestone '#{title}'")
        @milestones[title] = ghm[title][:number]
        next
      end
      opts = {}
      opts[:state] = m[:completed] == 0 ? 'open' : 'closed'
      opts[:description] = m[:description]
      begin
        t = DateTime.parse(m[:due])
        opts[:due_on] = t.to_time
      rescue
        $logger.warn("ignoring unparseable trac milestone date '#{m[:due]}'")
      end
      milestone = @gh.create_milestone(title, opts)
      @milestones[title] = milestone[:number]
    end
  end

  def migrate_tickets(insert_author = true)
    $logger.info('migrating issues')
    # We match the issue title to determine whether an issue exists already.
    ghi = Hash[@gh.list_issues.map { |i| [i[:title], i] }]
    @trac.tickets.each do |t|
      title = t[:summary]
      if ghi.has_key?(title)
        $logger.warn("skipping already existing issue '#{title}'")
        @issues[t[:id]] = ghi[title]
        next
      end
      opts = {}
      assignee = translate_username(t[:owner])
      opts[:assignee] = assignee if assignee
      milestone = @milestones[t[:milestone]]
      opts[:milestone] = milestone if milestone
      # TODO: labels
      body = markdownify(t[:description])
      if insert_author
        body.insert(0, "**Original reporter**: *#{t[:reporter]}*\n\n")
      end
      issue = @gh.create_issue(title, body, opts)
      ghi[title] = issue # Avoid adding issues having duplicate title.
      @issues[t[:id]] = issue
    end
  end

  def replay_changes
    $logger.info('replaying ticket changes')
    # FIXME: I cannot figure out how to get group(:ticket) working, it only
    # returns the first change of a given ticket as opposed to the whole group
    # of changes. Hence the weird loop thingy.
    @trac.changes.order(:ticket).each do |c|
      id = c[:ticket]
      issue = @issues[id]
      no = issue[:number]
      case c[:field]
      when 'milestone'
        ms = @milestones[c[:newvalue]]
        $logger.debug("issue #{no}: updating milestone to '#{ms}'")
        @gh.update_issue(no, issue[:title], issue[:body], :milestone => ms)
      when 'owner'
        if user = translate_username(c[:newvalue])
          $logger.debug("issue #{no}: updating assignee to '#{user}'")
          opts = {:assignee => user}
          @gh.update_issue(no, issue[:title], issue[:body], opts)
        end
      when 'status'
        case c[:newvalue]
        when 'closed'
          $logger.debug("issue #{no}: closing")
          @gh.close_issue(no)
        when 'reopened'
          $logger.debug("issue #{no}: reopening")
          @gh.reopen_issue(no)
        end
      when 'summary'
        $logger.debug("issue #{no}: updating title to '#{c[:newvalue]}'")
        @gh.update_issue(no, c[:newvalue], issue[:body])
      when 'description'
        $logger.debug("issue #{no}: updating body")
        reporter = issue.body.split("\n\n", 1)[0]
        body = [reporter, c[:newvalue]].join("\n\n")
        @gh.update_issue(no, issue[:title], body)
      when 'comment'
        body = c[:newvalue]
        next if body.empty? || body =~ /Milestone.*deleted/
        excerpt = body[0, 20].gsub("\n", ' ')
        excerpt << '...' if body.size > 20
        $logger.debug("issue #{no}: adding comment '#{excerpt}'")
        @gh.add_comment(no, body)
      when /resolution|priority|component|type|version/
        labels = translate_labels(issue, c[:field], c[:newvalue])
        @gh.update_issue(no, issue[:title], issue[:body], :labels => labels)
      when /keywords|cc|reporter/
        # TODO
      end
    end
  end

  def translate_username(user)
    @users[user]
  end

  def translate_labels(issue, category, label)
    i = issue[:number]
    old_labs = issue[:labels].map { |l| l[:name] }
    return nil unless @labels.has_key?(category)
    t, f = @labels[category].partition { |pat, rep| pat =~ label }
    if t.empty?
      $logger.warn("issue #{i}: no match for label '#{label}' in '#{category}'")
      return nil
    elsif t.size > 1
      $logger.error("issue #{i}: more than one match for '#{label}' in '#{category}'")
      exit 1
    end
    new_labs = old_labs.reject { |lab| f.find { |pat, rep|  pat =~ lab } }
    if old_labs.size != new_labs.size
      $logger.debug("issue #{i}: removed existing labels in '#{c[:field]}'")
    end
    new_label = t[0][1]
    $logger.debug("issue #{i}: adding label '#{new_label}'")
    new_labs << new_label
  end

  # Ripped from https://gist.github.com/somebox/619537
  def markdownify(str)
    str.gsub!(/\{\{\{([^\n]+?)\}\}\}/, '`\1`')
    str.gsub!(/\{\{\{(.+?)\}\}\}/m) do |m|
      m.each_line.map {|x| "\t#{x}".gsub(/[\{\}]{3}/,'') }.join
    end
    str.gsub!(/\=\=\=\=\s(.+?)\s\=\=\=\=/, '### \1')
    str.gsub!(/\=\=\=\s(.+?)\s\=\=\=/, '## \1')
    str.gsub!(/\=\=\s(.+?)\s\=\=/, '# \1')
    str.gsub!(/\=\s(.+?)\s\=[\s\n]*/, '')
    str.gsub!(/\[(http[^\s\[\]]+)\s([^\[\]]+)\]/, '[\2](\1)')
    str.gsub!(/\!(([A-Z][a-z0-9]+){2,})/, '\1')
    str.gsub!(/'''(.+)'''/, '*\1*')
    str.gsub!(/''(.+)''/, '_\1_')
    str.gsub!(/^\s\*/, '*')
    str.gsub!(/^\s\d\./, '1.')
    str
  end
end

class Trac
  attr_reader :milestones, :tickets, :changes
  def initialize(db)
    $logger.info('loading milestones and tickets')
    @db = db
    @milestones = @db[:milestone]
    @tickets = @db[:ticket]
    @changes = @db[:ticket_change]
  end
end

class GitHub
  def initialize(user, pass, repo)
    $logger.debug("connecting to github at repo '#{repo}'")
    @client = Octokit::Client.new(:login => user, :password => pass)
    @repo = repo
  end

  def collaborators
    @client.collaborators(@repo)
  end

  def list_milestones
    @client.list_milestones(@repo)
  end

  def create_milestone(*args)
    @client.create_milestone(@repo, *args)
  end

  def list_issues
    $logger.debug('fetching all issues')
    fetch { |i| @client.list_issues(@repo, :page => i) }
  end

  def create_issue(*args)
    $logger.debug("creating issue '#{args[0]}'")
    if args[1].size > 2**16
      msg = "\n\n*(issue truncated due to size)*"
      $logger.warn("truncating issue '#{args[0]}' (#{args[1].size} bytes)")
      args[1] = args[1][0, 65300] + msg
    end
    @client.create_issue(@repo, *args)
  end

  def update_issue(*args)
    @client.update_issue(@repo, *args)
  end

  def close_issue(*args)
    @client.close_issue(@repo, *args)
  end

  def reopen_issue(*args)
    @client.reopen_issue(@repo, *args)
  end

  def add_comment(*args)
    @client.add_comment(@repo, *args)
  end

  private

  def fetch
    result = []
    begin
      i = 1;
      loop do
        $logger.debug("fetching page #{i}")
        page = yield i
        break if page.empty?
        result += page
        i += 1
      end
    end
    $logger.debug("fetched #{result.size} elements")
    result
  end
end

class Options < Hash
  def initialize(argv)
    super()
    opts = OptionParser.new do |opts|
      opts.banner = "#{$0}, available options:"
      opts.on('-c config', '--config', 'set the configuration file') do |c|
        self[:config] = c
      end
      opts.on_tail('-h', '--help', 'display this help and exit') do |help|
        puts(opts)
        exit
      end
      opts.on('-v', '--verbose', 'be verbose') do |v|
        self[:verbose] = v
      end
      begin
        opts.parse!(argv)
        raise 'missing configuration file' unless self[:config]
      rescue => e
        STDERR.puts(e)
        STDERR.puts('run with -h to see available options')
        exit 1
      end
    end
  end
end

if __FILE__ == $0
  opts = Options.new(ARGV)
  cfg = YAML.load_file(opts[:config])

  # Setup logger.
  $logger = Logger.new(STDERR)
  $logger.level = opts[:verbose] ? Logger::DEBUG : Logger::INFO
  $logger.formatter = proc do |severity, datetime, progname, msg|
    time = datetime.strftime('%Y-%m-%d %H:%M:%S')
    "[#{time}] #{severity}#{' ' * (5 - severity.size + 1)}| #{msg}\n"
  end

  # Setup database.
  db = nil
  if sqlite = cfg['trac']['sqlite']
    file = sqlite['file']
    if not File.exists?(file)
      $logger.error("no such file: #{file}")
      exit 1
    end
    $logger.debug("connecting to SQLite databse '#{file}'")
    db = Sequel.sqlite(file)
  end
  if not db
    $logger.error('could not connect to trac databse')
    exit 1
  end

  trac = Trac.new(db)
  gh = cfg['github']
  github = GitHub.new(gh['user'], gh['pass'], gh['repo'])
  migrator = Migrator.new(trac, github, cfg['users'], cfg['labels'])
  migrator.migrate
end
